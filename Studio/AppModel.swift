import AppKit
import Foundation

enum AppTab: Hashable {
    case record
    case history
}

enum Route: Equatable {
    case main
    /// The microphone setup assistant, starting at a given step (0…3).
    case micSetup(step: Int)
    case nasSetup
}

/// Where the user is in the app.
final class Navigation: ObservableObject {
    @Published var tab: AppTab = .record
    @Published var route: Route = .main
}

/// Creates the services once and wires them together.
final class AppModel: ObservableObject {
    static private(set) weak var shared: AppModel?

    let settings: AppSettings
    let devices: AudioDeviceMonitor
    let audio: AudioEngineController
    let camera: CameraController
    let nas: NASManager
    let library: Library
    let recorder: RecorderCoordinator
    let playback = PlaybackController()
    let navigation = Navigation()

    private var observers: [NSObjectProtocol] = []
    private var retryTimer: Timer?

    init() {
        settings = AppSettings()
        devices = AudioDeviceMonitor(settings: settings)
        audio = AudioEngineController()
        camera = CameraController()
        nas = NASManager(settings: settings)
        library = Library(nas: nas)
        recorder = RecorderCoordinator(
            settings: settings,
            devices: devices,
            audio: audio,
            camera: camera,
            library: library
        )
        AppModel.shared = self

        nas.onAvailable = { [weak self] in
            self?.library.processPendingCopies()
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.recorder.activate()
            self?.retryPendingCopies()
        })
        // Free the microphone and the camera when the app is in the background and idle.
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.navigation.route == .main else { return }
            self.recorder.deactivate()
        })

        // Recordings waiting for the NAS are retried regularly, with no action from the user.
        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            self?.retryPendingCopies()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func retryPendingCopies() {
        guard library.pendingCount > 0, nas.isConfigured else { return }
        nas.refreshAvailability { [weak self] available in
            if available { self?.library.processPendingCopies() }
        }
    }

    /// True when quitting now would lose something.
    var hasUnsavedWork: Bool {
        recorder.isBusy || recorder.finished != nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared?.hasUnsavedWork == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Un enregistrement n'est pas terminé"
        alert.informativeText = "Terminez et enregistrez-le avant de quitter Studio, sinon il serait perdu."
        alert.addButton(withTitle: "Revenir à Studio")
        alert.runModal()
        return .terminateCancel
    }
}
