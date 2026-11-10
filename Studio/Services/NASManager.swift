import AppKit
import Foundation
import NetFS
import Network

/// One line of the reconnection checklist.
struct NASCheck: Identifiable, Equatable {
    enum Kind: Int {
        case tailscaleInstalled
        case tailscaleConnected
        case nasMounted
        case folderFound
    }

    enum State: Equatable {
        case pending
        case running
        case ok
        case failed
    }

    let kind: Kind
    var state: State
    var detail: String

    var id: Int { kind.rawValue }
}

/// Knows where the NAS folder is, whether it is reachable, and how to get it back
/// (Tailscale connected, share mounted) when it is not.
final class NASManager: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isChecking = false
    @Published private(set) var checks: [NASCheck] = NASManager.initialChecks()

    /// Called on the main queue each time the NAS becomes available.
    var onAvailable: (() -> Void)?

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "ch.viorizz.studio.nas", qos: .utility)

    init(settings: AppSettings) {
        self.settings = settings
        refreshAvailability()
    }

    var isConfigured: Bool {
        settings.nasFolderPath != nil
    }

    var folderURL: URL? {
        settings.nasFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var displayName: String {
        settings.nasName ?? "NAS"
    }

    // MARK: Configuration

    /// Remembers a folder picked on a mounted network volume, with the address needed to mount it again.
    /// Returns false when the folder is on the Mac's own disk.
    @discardableResult
    func configure(folder: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeNameKey, .volumeURLForRemountingKey]
        let values = try? folder.resourceValues(forKeys: keys)
        if values?.volumeIsLocal ?? true { return false }
        settings.nasFolderPath = folder.path
        settings.nasName = values?.volumeName ?? folder.lastPathComponent
        settings.nasRemountURL = values?.volumeURLForRemounting?.absoluteString
        isAvailable = true
        onAvailable?()
        return true
    }

    func forget() {
        settings.nasFolderPath = nil
        settings.nasName = nil
        settings.nasRemountURL = nil
        isAvailable = false
    }

    // MARK: Availability

    private static func folderExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Checks off the main thread: `stat` on a dead network mount can block for a long time.
    func refreshAvailability(_ completion: ((Bool) -> Void)? = nil) {
        let folder = folderURL
        queue.async { [weak self] in
            let available = Self.folderExists(folder)
            DispatchQueue.main.async {
                guard let self else { return }
                let becameAvailable = available && !self.isAvailable
                if self.isAvailable != available { self.isAvailable = available }
                if becameAvailable { self.onAvailable?() }
                completion?(available)
            }
        }
    }

    // MARK: Reconnection

    private static func initialChecks() -> [NASCheck] {
        [
            NASCheck(kind: .tailscaleInstalled, state: .pending, detail: ""),
            NASCheck(kind: .tailscaleConnected, state: .pending, detail: ""),
            NASCheck(kind: .nasMounted, state: .pending, detail: ""),
            NASCheck(kind: .folderFound, state: .pending, detail: "")
        ]
    }

    private func set(_ kind: NASCheck.Kind, _ state: NASCheck.State, _ detail: String) {
        guard let index = checks.firstIndex(where: { $0.kind == kind }) else { return }
        checks[index].state = state
        checks[index].detail = detail
    }

    /// Runs the checklist: Tailscale installed → Tailscale connected → share mounted → folder found.
    /// Stops at the first failing step so the screen shows exactly what to fix.
    func reconnect() {
        guard !isChecking else { return }
        isChecking = true
        checks = Self.initialChecks()
        let folder = folderURL
        let remount = settings.nasRemountURL.flatMap(URL.init(string:))

        set(.tailscaleInstalled, .running, "Vérification…")
        queue.async { [weak self] in
            guard let self else { return }

            // Already reachable: nothing to repair.
            if Self.folderExists(folder) {
                self.finish(allOK: true)
                return
            }

            guard Tailscale.appURL != nil || Tailscale.cliURL != nil else {
                self.update(.tailscaleInstalled, .failed, "Tailscale n'est pas installé sur ce Mac.")
                self.finish(allOK: false)
                return
            }
            self.update(.tailscaleInstalled, .ok, "C'est bon")

            self.update(.tailscaleConnected, .running, "Vérification…")
            switch Tailscale.backendState() {
            case .running, .unknown:
                // Unknown: the command line tool gave no answer; the mount attempt below will tell.
                self.update(.tailscaleConnected, .ok, "C'est bon")
            case .stopped:
                self.update(
                    .tailscaleConnected,
                    .failed,
                    "Ouvrez Tailscale puis cliquez sur « Se connecter ». Cliquez ensuite sur Réessayer."
                )
                self.finish(allOK: false)
                return
            }

            self.update(.nasMounted, .running, "Connexion au NAS…")
            guard let remount else {
                self.update(.nasMounted, .failed, "Adresse du NAS inconnue. Reconnectez le NAS depuis le Finder, puis choisissez à nouveau le dossier.")
                self.finish(allOK: false)
                return
            }
            if let host = remount.host, !Reachability.canConnect(host: host, port: remount.port ?? 445, timeout: 5) {
                self.update(.nasMounted, .failed, "Le NAS ne répond pas. Vérifiez qu'il est allumé et que Tailscale est connecté.")
                self.finish(allOK: false)
                return
            }
            NetworkMount.mount(remount) { success in
                self.queue.async {
                    guard success else {
                        self.update(.nasMounted, .failed, "Impossible d'ouvrir le partage du NAS. Vérifiez l'identifiant et le mot de passe.")
                        self.finish(allOK: false)
                        return
                    }
                    self.update(.nasMounted, .ok, "C'est bon")
                    self.update(.folderFound, .running, "Recherche du dossier…")
                    if Self.folderExists(folder) {
                        self.finish(allOK: true)
                    } else {
                        self.update(.folderFound, .failed, "Le dossier d'enregistrement est introuvable sur le NAS. Choisissez-le à nouveau.")
                        self.finish(allOK: false)
                    }
                }
            }
        }
    }

    private func update(_ kind: NASCheck.Kind, _ state: NASCheck.State, _ detail: String) {
        DispatchQueue.main.async { [weak self] in
            self?.set(kind, state, detail)
        }
    }

    private func finish(allOK: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if allOK {
                for index in self.checks.indices {
                    self.checks[index].state = .ok
                    self.checks[index].detail = "C'est bon"
                }
            }
            self.isChecking = false
            let becameAvailable = allOK && !self.isAvailable
            if self.isAvailable != allOK { self.isAvailable = allOK }
            if becameAvailable { self.onAvailable?() }
        }
    }
}

// MARK: - Tailscale

enum Tailscale {
    enum BackendState {
        case running
        case stopped
        case unknown
    }

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
            ?? existing("/Applications/Tailscale.app")
    }

    /// The command line tool: bundled inside the app, or installed by Homebrew.
    static var cliURL: URL? {
        if let app = appURL {
            let bundled = app.appendingPathComponent("Contents/MacOS/Tailscale")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        return existing("/opt/homebrew/bin/tailscale") ?? existing("/usr/local/bin/tailscale")
    }

    private static func existing(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func open() {
        if let app = appURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Asks `tailscale status --json` whether the VPN is up. Blocking: call off the main thread.
    static func backendState() -> BackendState {
        guard let cli = cliURL else { return .unknown }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .unknown
        }
        // Never let a stuck command line tool freeze the checklist.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["BackendState"] as? String else { return .unknown }
        return state == "Running" ? .running : .stopped
    }
}

// MARK: - Reachability

enum Reachability {
    /// Tries a TCP connection. Blocking: call off the main thread.
    static func canConnect(host: String, port: Int, timeout: TimeInterval) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result.set(true)
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.stateUpdateHandler = nil
        connection.cancel()
        return result.value
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false

        func set(_ newValue: Bool) {
            lock.lock()
            stored = newValue
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}

// MARK: - Mounting

enum NetworkMount {
    /// Mounts a network share with the system's own machinery (Keychain, password prompt).
    /// `completion` is called on the main queue.
    static func mount(_ url: URL, completion: @escaping (Bool) -> Void) {
        let openOptions = NSMutableDictionary()
        let mountOptions = NSMutableDictionary()
        var requestID: AsyncRequestID?
        var completed = false
        let finish: (Bool) -> Void = { success in
            // Both the block and the immediate status run on the main queue; report once.
            if completed { return }
            completed = true
            completion(success)
        }
        DispatchQueue.main.async {
            let status = NetFSMountURLAsync(
                url as CFURL,
                nil,
                nil,
                nil,
                openOptions as CFMutableDictionary,
                mountOptions as CFMutableDictionary,
                &requestID,
                DispatchQueue.main
            ) { status, _, _ in
                // EEXIST: the share is already mounted.
                finish(status == 0 || status == EEXIST)
            }
            if status != 0 {
                finish(status == EEXIST)
            }
        }
    }
}
