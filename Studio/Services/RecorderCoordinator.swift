import AVFoundation
import Combine
import Foundation
import StudioCore

/// A recording that has just ended and waits for the user to name and save it.
struct FinishedRecording: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let kind: RecordingKind
    let date: Date
    let duration: TimeInterval
    /// Something the user should know (for example the microphone was unplugged).
    let note: String?
}

/// Drives a recording from the big button to the save sheet, for audio and video.
final class RecorderCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case finishing
    }

    @Published var mode: RecordingKind = .audio {
        didSet { if mode != oldValue { modeChanged() } }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var finished: FinishedRecording?
    @Published var errorMessage: String?
    @Published private(set) var microphoneDenied = false
    @Published private(set) var cameraDenied = false

    private let settings: AppSettings
    private let devices: AudioDeviceMonitor
    private let audio: AudioEngineController
    private let camera: CameraController
    private let library: Library

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var accumulated: TimeInterval = 0
    private var resumedAt: Date?
    private var currentURL: URL?
    private var currentKind: RecordingKind = .audio
    private var startDate = Date()
    private var isActive = false

    init(settings: AppSettings, devices: AudioDeviceMonitor, audio: AudioEngineController, camera: CameraController, library: Library) {
        self.settings = settings
        self.devices = devices
        self.audio = audio
        self.camera = camera
        self.library = library

        devices.$selectedUID
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartCapture() }
            .store(in: &cancellables)

        // Plugging headphones in or out changes whether monitoring is possible.
        devices.$outputRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartCapture() }
            .store(in: &cancellables)

        audio.onConfigurationChange = { [weak self] in
            self?.engineConfigurationChanged()
        }
        camera.onUnexpectedFinish = { [weak self] url, usable in
            self?.videoEndedUnexpectedly(url: url, usable: usable)
        }
    }

    var isBusy: Bool {
        phase != .idle
    }

    // MARK: Capture lifecycle

    /// Starts listening to the microphone (asks for permission the first time).
    func activate() {
        if isActive, audio.isRunning { return }
        isActive = true
        Permissions.request(.audio) { [weak self] granted in
            guard let self else { return }
            self.microphoneDenied = !granted
            if granted { self.restartCapture() }
        }
    }

    /// Releases the microphone and the camera while the app is in the background and idle.
    func deactivate() {
        guard phase == .idle else { return }
        isActive = false
        audio.stop()
        camera.stop()
    }

    /// (Re)opens the selected microphone with the current settings. Never interrupts a recording.
    func restartCapture() {
        guard isActive, phase == .idle, !microphoneDenied else { return }
        guard let device = devices.selected else {
            audio.stop()
            return
        }
        let gain = settings.micGains[device.uid] ?? CoreAudioHelper.inputVolume(device.id) ?? 0.5
        audio.start(
            AudioEngineController.Configuration(
                device: device,
                gain: gain,
                noiseReduction: settings.noiseReduction,
                monitoring: settings.monitoringEnabled,
                monitorVolume: settings.monitorVolume
            )
        )
        if mode == .video {
            startCamera()
        }
    }

    private func modeChanged() {
        guard phase == .idle else { return }
        if mode == .video {
            camera.requestAccess { [weak self] granted in
                guard let self else { return }
                self.cameraDenied = !granted
                if granted, self.mode == .video { self.startCamera() }
            }
        } else {
            camera.stop()
        }
    }

    private func startCamera() {
        camera.start(cameraID: settings.cameraID, microphoneUID: devices.selectedUID)
    }

    func selectCamera(_ id: String) {
        settings.cameraID = id
        if mode == .video, phase == .idle {
            startCamera()
        }
    }

    // MARK: Recording

    func start() {
        guard phase == .idle, finished == nil else { return }
        Permissions.request(.audio) { [weak self] granted in
            guard let self else { return }
            self.microphoneDenied = !granted
            guard granted else { return }
            if !self.audio.isRunning { self.restartCapture() }
            self.begin()
        }
    }

    private func begin() {
        let date = Date()
        let url = library.newRecordingURL(date: date, kind: mode)
        switch mode {
        case .audio:
            do {
                try audio.beginRecording(to: url)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        case .video:
            guard camera.isRunning else {
                errorMessage = "La caméra n'est pas prête. Vérifiez qu'elle est branchée, puis réessayez."
                return
            }
            camera.startRecording(to: url)
        }
        currentURL = url
        currentKind = mode
        startDate = date
        accumulated = 0
        resumedAt = Date()
        elapsed = 0
        phase = .recording
        startTimer()
    }

    func togglePause() {
        switch phase {
        case .recording:
            accumulated = currentElapsed()
            resumedAt = nil
            setPaused(true)
            phase = .paused
        case .paused:
            resumedAt = Date()
            setPaused(false)
            phase = .recording
        default:
            break
        }
    }

    private func setPaused(_ paused: Bool) {
        if currentKind == .audio {
            audio.setPaused(paused)
        } else {
            camera.setPaused(paused)
        }
    }

    func stop() {
        stop(note: nil)
    }

    private func stop(note: String?) {
        guard phase == .recording || phase == .paused, let url = currentURL else { return }
        let measured = currentElapsed()
        stopTimer()
        phase = .finishing
        switch currentKind {
        case .audio:
            let result = audio.endRecording()
            let duration = result.duration > 0 ? result.duration : measured
            let message = result.failed
                ? "Une erreur d'écriture s'est produite : la fin de l'enregistrement peut manquer."
                : note
            complete(url: url, duration: duration, usable: result.duration > 0, note: message)
        case .video:
            camera.stopRecording { [weak self] fileURL, usable in
                self?.complete(url: fileURL ?? url, duration: measured, usable: usable, note: note)
            }
        }
    }

    private func complete(url: URL, duration: TimeInterval, usable: Bool, note: String?) {
        phase = .idle
        currentURL = nil
        elapsed = 0
        guard usable, FileManager.default.fileExists(atPath: url.path) else {
            library.discard(fileURL: url)
            errorMessage = "L'enregistrement n'a pas pu être finalisé."
            return
        }
        finished = FinishedRecording(url: url, kind: currentKind, date: startDate, duration: duration, note: note)
    }

    // MARK: Save sheet

    func saveFinished(name: String, location: SaveLocation, makeDefault: Bool) {
        guard let finished else { return }
        if makeDefault {
            settings.saveLocation = location
        }
        library.add(
            fileURL: finished.url,
            name: name,
            date: finished.date,
            duration: finished.duration,
            kind: finished.kind,
            location: location
        )
        self.finished = nil
    }

    func discardFinished() {
        guard let finished else { return }
        library.discard(fileURL: finished.url)
        self.finished = nil
    }

    // MARK: Interruptions

    private func engineConfigurationChanged() {
        let recordingAudio = (phase == .recording || phase == .paused) && currentKind == .audio
        if recordingAudio {
            if audio.resumeAfterConfigurationChange() { return }
            stop(note: "Le micro a été débranché ou modifié : l'enregistrement s'est arrêté à ce moment-là.")
        }
        devices.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.restartCapture()
        }
    }

    private func videoEndedUnexpectedly(url: URL, usable: Bool) {
        guard phase == .recording || phase == .paused, currentKind == .video else { return }
        let measured = currentElapsed()
        stopTimer()
        complete(
            url: url,
            duration: measured,
            usable: usable,
            note: "La vidéo s'est arrêtée toute seule (caméra débranchée ou disque plein)."
        )
    }

    // MARK: Stopwatch

    private func currentElapsed() -> TimeInterval {
        accumulated + (resumedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = self.currentElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
