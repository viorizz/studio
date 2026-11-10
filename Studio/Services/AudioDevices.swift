import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool

    var isYeti: Bool {
        name.localizedCaseInsensitiveContains("yeti")
    }
}

/// Thin wrappers around the CoreAudio HAL property API.
enum CoreAudioHelper {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(system, &addr, 0, nil, &size, base)
        }
        return status == noErr ? ids : []
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { (id: AudioDeviceID) -> AudioInputDevice? in
            guard hasStreams(id, scope: kAudioObjectPropertyScopeInput) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            // Aggregates are created by the system (and by AVAudioEngine) and are not real microphones.
            if transport == kAudioDeviceTransportTypeAggregate { return nil }
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
            )
        }
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        guard let id = uint32(system, selector), id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// True when sound would come out of the Mac's own speakers: monitoring the
    /// microphone through them would feed back.
    static func isBuiltInSpeaker(_ id: AudioDeviceID) -> Bool {
        guard uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn else { return false }
        // Intel Macs expose speakers and headphone jack as data sources of one device.
        if let source = uint32(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput) {
            return source == fourCC("ispk")
        }
        // Apple Silicon Macs expose them as separate devices; only the name tells them apart.
        let name = (string(id, kAudioObjectPropertyName) ?? "").lowercased()
        return name.contains("speaker") || name.contains("haut-parleur")
    }

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    // MARK: Input volume

    private static func volumeAddresses(_ id: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        [kAudioObjectPropertyElementMain, 1, 2].compactMap { (element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress? in
            var addr = address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeInput,
                element: element
            )
            guard AudioObjectHasProperty(id, &addr) else { return nil }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else { return nil }
            return addr
        }
    }

    static func hasInputVolume(_ id: AudioDeviceID) -> Bool {
        !volumeAddresses(id).isEmpty
    }

    static func inputVolume(_ id: AudioDeviceID) -> Double? {
        guard var addr = volumeAddresses(id).first else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    /// Sets the hardware/driver input volume. Returns false when the device has none.
    @discardableResult
    static func setInputVolume(_ id: AudioDeviceID, _ volume: Double) -> Bool {
        let addresses = volumeAddresses(id)
        guard !addresses.isEmpty else { return false }
        var value = Float32(min(1, max(0, volume)))
        var success = false
        for var addr in addresses {
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value) == noErr {
                success = true
            }
        }
        return success
    }

    // MARK: Change notifications

    static func observe(_ selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        var addr = address(selector)
        _ = AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in
            handler()
        }
    }
}

/// What the app should tell the user about the microphone.
enum MicStatus: Equatable {
    /// The Mac has no microphone at all.
    case noInput
    /// Only the Mac's own microphone is available.
    case noExternalMic
    /// An external microphone is plugged in but the Mac's microphone is selected.
    case usingBuiltIn(externalName: String)
    /// An external microphone is selected.
    case ready
}

/// Publishes the list of microphones and the one in use, and follows plug/unplug events.
final class AudioDeviceMonitor: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var selectedUID: String?
    @Published private(set) var outputRevision = 0

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        refresh()
        CoreAudioHelper.observe(kAudioHardwarePropertyDevices) { [weak self] in
            self?.refresh()
        }
        CoreAudioHelper.observe(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.outputRevision += 1
        }
    }

    var selected: AudioInputDevice? {
        devices.first { $0.uid == selectedUID }
    }

    var externalDevices: [AudioInputDevice] {
        devices.filter { !$0.isBuiltIn }
    }

    /// The external microphone to suggest: the preferred one, else a Yeti, else the first.
    var suggestedExternal: AudioInputDevice? {
        let externals = externalDevices
        let preferred = settings.preferredMicUID
        return externals.first(where: { $0.uid == preferred })
            ?? externals.first(where: { $0.isYeti })
            ?? externals.first
    }

    var status: MicStatus {
        guard let selected else { return .noInput }
        if !selected.isBuiltIn { return .ready }
        if let external = suggestedExternal { return .usingBuiltIn(externalName: external.name) }
        return .noExternalMic
    }

    func select(_ uid: String) {
        guard devices.contains(where: { $0.uid == uid }) else { return }
        if selectedUID != uid { selectedUID = uid }
    }

    func refresh() {
        let list = CoreAudioHelper.inputDevices().sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return !a.isBuiltIn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if list != devices { devices = list }

        var uid = selectedUID
        if settings.autoUsePreferredMic,
           let preferred = settings.preferredMicUID,
           list.contains(where: { $0.uid == preferred }) {
            uid = preferred
        } else if uid == nil || !list.contains(where: { $0.uid == uid }) {
            // Fall back to the Mac's microphone (never silently to an unknown external one).
            let defaultID = CoreAudioHelper.defaultInputDevice()
            let fallback = list.first(where: { $0.isBuiltIn })
                ?? list.first(where: { $0.id == defaultID })
                ?? list.first
            uid = fallback?.uid
        }
        if uid != selectedUID { selectedUID = uid }
    }
}
