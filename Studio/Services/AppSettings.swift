import Foundation
import StudioCore

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// Microphone chosen during setup (CoreAudio device UID).
    @Published var preferredMicUID: String? {
        didSet { defaults.set(preferredMicUID, forKey: Key.preferredMicUID) }
    }
    /// Switch to the preferred microphone automatically whenever it is plugged in.
    @Published var autoUsePreferredMic: Bool {
        didSet { defaults.set(autoUsePreferredMic, forKey: Key.autoUsePreferredMic) }
    }
    /// Devices that went through the setup assistant.
    @Published var configuredMicUIDs: [String] {
        didSet { defaults.set(configuredMicUIDs, forKey: Key.configuredMicUIDs) }
    }
    /// Microphone volume per device UID (0…1).
    @Published var micGains: [String: Double] {
        didSet { defaults.set(micGains, forKey: Key.micGains) }
    }
    @Published var noiseReduction: Double {
        didSet { defaults.set(noiseReduction, forKey: Key.noiseReduction) }
    }
    @Published var monitoringEnabled: Bool {
        didSet { defaults.set(monitoringEnabled, forKey: Key.monitoringEnabled) }
    }
    @Published var monitorVolume: Double {
        didSet { defaults.set(monitorVolume, forKey: Key.monitorVolume) }
    }
    @Published var saveLocation: SaveLocation {
        didSet { defaults.set(saveLocation.rawValue, forKey: Key.saveLocation) }
    }
    @Published var cameraID: String? {
        didSet { defaults.set(cameraID, forKey: Key.cameraID) }
    }
    @Published var nasFolderPath: String? {
        didSet { defaults.set(nasFolderPath, forKey: Key.nasFolderPath) }
    }
    @Published var nasRemountURL: String? {
        didSet { defaults.set(nasRemountURL, forKey: Key.nasRemountURL) }
    }
    @Published var nasName: String? {
        didSet { defaults.set(nasName, forKey: Key.nasName) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredMicUID = defaults.string(forKey: Key.preferredMicUID)
        autoUsePreferredMic = defaults.object(forKey: Key.autoUsePreferredMic) as? Bool ?? true
        configuredMicUIDs = defaults.stringArray(forKey: Key.configuredMicUIDs) ?? []
        micGains = defaults.dictionary(forKey: Key.micGains) as? [String: Double] ?? [:]
        noiseReduction = defaults.object(forKey: Key.noiseReduction) as? Double ?? 0.35
        monitoringEnabled = defaults.object(forKey: Key.monitoringEnabled) as? Bool ?? false
        monitorVolume = defaults.object(forKey: Key.monitorVolume) as? Double ?? 0.5
        saveLocation = SaveLocation(rawValue: defaults.string(forKey: Key.saveLocation) ?? "") ?? .mac
        cameraID = defaults.string(forKey: Key.cameraID)
        nasFolderPath = defaults.string(forKey: Key.nasFolderPath)
        nasRemountURL = defaults.string(forKey: Key.nasRemountURL)
        nasName = defaults.string(forKey: Key.nasName)
    }

    func isConfigured(_ uid: String) -> Bool {
        configuredMicUIDs.contains(uid)
    }

    func markConfigured(_ uid: String) {
        if !configuredMicUIDs.contains(uid) {
            configuredMicUIDs.append(uid)
        }
    }

    private enum Key {
        static let preferredMicUID = "preferredMicUID"
        static let autoUsePreferredMic = "autoUsePreferredMic"
        static let configuredMicUIDs = "configuredMicUIDs"
        static let micGains = "micGains"
        static let noiseReduction = "noiseReduction"
        static let monitoringEnabled = "monitoringEnabled"
        static let monitorVolume = "monitorVolume"
        static let saveLocation = "saveLocation"
        static let cameraID = "cameraID"
        static let nasFolderPath = "nasFolderPath"
        static let nasRemountURL = "nasRemountURL"
        static let nasName = "nasName"
    }
}
