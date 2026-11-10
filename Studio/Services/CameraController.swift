import AppKit
import AVFoundation
import Foundation

struct CameraDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Camera preview and video recording. Video files are written by
/// AVCaptureMovieFileOutput, with the selected microphone as the audio track.
final class CameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()

    @Published private(set) var cameras: [CameraDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isAuthorized = true

    private let queue = DispatchQueue(label: "ch.viorizz.studio.camera", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    private var finishHandler: ((URL?, Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// Called on the main queue when a recording stops without `stopRecording` being asked.
    var onUnexpectedFinish: ((URL, Bool) -> Void)?

    override init() {
        super.init()
        refreshCameras()
        let center = NotificationCenter.default
        // Raw names: the Swift spelling of these two notifications changed between SDKs.
        let names = ["AVCaptureDeviceWasConnectedNotification", "AVCaptureDeviceWasDisconnectedNotification"]
        for name in names.map(Notification.Name.init(rawValue:)) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshCameras()
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private static func discoverCameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    func refreshCameras() {
        let list = Self.discoverCameras().map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
        if list != cameras { cameras = list }
    }

    /// Asks for camera access if needed, then calls back on the main queue.
    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        Permissions.request(.video) { [weak self] granted in
            self?.isAuthorized = granted
            completion(granted)
        }
    }

    /// Starts the preview with a camera and the microphone used for the sound.
    func start(cameraID: String?, microphoneUID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            let session = self.session
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if session.canSetSessionPreset(.high) {
                session.sessionPreset = .high
            }

            let cameras = Self.discoverCameras()
            let camera = cameras.first(where: { $0.uniqueID == cameraID }) ?? cameras.first
            if let camera,
               let input = try? AVCaptureDeviceInput(device: camera),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if let microphoneUID,
               let microphone = AVCaptureDevice(uniqueID: microphoneUID),
               let input = try? AVCaptureDeviceInput(device: microphone),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if !session.outputs.contains(self.movieOutput), session.canAddOutput(self.movieOutput) {
                session.addOutput(self.movieOutput)
            }
            session.commitConfiguration()

            if !session.isRunning {
                session.startRunning()
            }
            let running = session.isRunning
            DispatchQueue.main.async {
                self.isRunning = running
            }
        }
    }

    /// Stops the preview (and switches the camera light off).
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    // MARK: Recording

    var isRecording: Bool {
        movieOutput.isRecording
    }

    func startRecording(to url: URL) {
        queue.async { [weak self] in
            guard let self, self.session.isRunning, !self.movieOutput.isRecording else { return }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            if paused {
                self.movieOutput.pauseRecording()
            } else {
                self.movieOutput.resumeRecording()
            }
        }
    }

    /// Stops the recording. `completion` (main queue) receives the file and whether it is usable.
    func stopRecording(_ completion: @escaping (URL?, Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.movieOutput.isRecording else {
                DispatchQueue.main.async { completion(nil, false) }
                return
            }
            self.finishHandler = completion
            self.movieOutput.stopRecording()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        var usable = true
        if let error = error as NSError? {
            // The file is still complete for "soft" errors such as a full disk or a size limit.
            usable = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        }
        queue.async { [weak self] in
            guard let self else { return }
            let handler = self.finishHandler
            self.finishHandler = nil
            DispatchQueue.main.async {
                if let handler {
                    handler(outputFileURL, usable)
                } else {
                    // The recording ended on its own (camera unplugged, disk full…).
                    self.onUnexpectedFinish?(outputFileURL, usable)
                }
            }
        }
    }
}

enum Permissions {
    /// Requests access to the microphone (.audio) or the camera (.video); calls back on the main queue.
    static func request(_ mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    /// Opens the Privacy pane of System Settings for the microphone or the camera.
    static func openSettings(for mediaType: AVMediaType) {
        let pane = mediaType == .video ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
