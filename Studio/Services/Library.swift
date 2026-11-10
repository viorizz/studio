import AppKit
import Foundation
import StudioCore

/// The history: an index of recordings plus the file operations around it
/// (saving, copying to the NAS, renaming, deleting, revealing in the Finder).
/// File work runs on a background queue; published state changes on the main queue.
final class Library: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    /// Recordings currently being copied.
    @Published private(set) var busyIDs: Set<UUID> = []

    let localFolder: URL
    private let indexURL: URL
    private let nas: NASManager
    private let queue = DispatchQueue(label: "ch.viorizz.studio.library", qos: .utility)

    init(nas: NASManager) {
        self.nas = nas
        let fileManager = FileManager.default
        let music = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        localFolder = music.appendingPathComponent("Studio", isDirectory: true)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        indexURL = support.appendingPathComponent("Studio/library.json")

        try? fileManager.createDirectory(at: localFolder, withIntermediateDirectories: true)
        recordings = LibraryFile.load(from: indexURL)
        reconcileLocalFiles()
    }

    var pendingCount: Int {
        recordings.filter(\.pendingNASCopy).count
    }

    // MARK: Paths

    func localURL(for recording: Recording) -> URL {
        localFolder.appendingPathComponent(recording.fileName)
    }

    func nasURL(for recording: Recording) -> URL? {
        nas.folderURL?.appendingPathComponent(recording.fileName)
    }

    /// The best file to play, reveal or share: the local copy, else the NAS copy when reachable.
    func accessibleURL(for recording: Recording) -> URL? {
        if recording.onMac { return localURL(for: recording) }
        if recording.onNAS, nas.isAvailable { return nasURL(for: recording) }
        return nil
    }

    /// A free file name in the local folder for a recording starting now.
    func newRecordingURL(date: Date, kind: RecordingKind) -> URL {
        let folder = localFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let taken = Set(recordings.map(\.fileName))
        let name = RecordingNamer.uniqueFileName(RecordingNamer.fileName(date: date, kind: kind)) { candidate in
            taken.contains(candidate)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }
        return folder.appendingPathComponent(name)
    }

    // MARK: Index

    private func persist() {
        let snapshot = recordings
        let url = indexURL
        queue.async {
            try? LibraryFile.save(snapshot, to: url)
        }
    }

    private func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[index])
    }

    /// Drops the "on this Mac" flag of files that were removed from the Finder,
    /// and forgets entries that no longer exist anywhere.
    private func reconcileLocalFiles() {
        let snapshot = recordings
        let folder = localFolder
        queue.async { [weak self] in
            let missing = snapshot
                .filter { $0.onMac && !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
                .map(\.id)
            guard !missing.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for id in missing {
                    self.update(id) { recording in
                        recording.onMac = false
                        recording.pendingNASCopy = false
                        recording.removeLocalAfterNASCopy = false
                    }
                }
                self.recordings.removeAll { !$0.onMac && !$0.onNAS }
                self.persist()
            }
        }
    }

    // MARK: Saving

    /// Adds a finished recording (already written in the local folder) to the history.
    func add(fileURL: URL, name: String, date: Date, duration: TimeInterval, kind: RecordingKind, location: SaveLocation) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var recording = Recording(
            name: trimmed.isEmpty ? RecordingNamer.defaultName(date: date, kind: kind) : trimmed,
            fileName: fileURL.lastPathComponent,
            date: date,
            duration: duration,
            kind: kind
        )
        recording.apply(location)
        recordings.insert(recording, at: 0)
        persist()
        processPendingCopies()
    }

    /// Throws away a recording that the user chose not to keep.
    func discard(fileURL: URL) {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: NAS copies

    /// Copies every queued recording to the NAS, if it is reachable. Safe to call often.
    func processPendingCopies() {
        guard let nasFolder = nas.folderURL else { return }
        let pending = recordings.filter { $0.pendingNASCopy && !busyIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        pending.forEach { busyIDs.insert($0.id) }
        let folder = localFolder

        queue.async { [weak self] in
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            let reachable = fileManager.fileExists(atPath: nasFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            var outcomes: [UUID: Bool] = [:]
            for recording in pending {
                guard reachable else {
                    outcomes[recording.id] = false
                    continue
                }
                let source = folder.appendingPathComponent(recording.fileName)
                let destination = nasFolder.appendingPathComponent(recording.fileName)
                let copied = Self.copy(source, to: destination)
                if copied, recording.removeLocalAfterNASCopy {
                    try? fileManager.removeItem(at: source)
                }
                outcomes[recording.id] = copied
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, success) in outcomes {
                    self.update(id) { $0.nasCopyFinished(success: success) }
                    self.busyIDs.remove(id)
                }
                self.persist()
            }
        }
    }

    /// Copies through a temporary name so an interrupted transfer never leaves a truncated file.
    private static func copy(_ source: URL, to destination: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let partial = destination.appendingPathExtension("partiel")
        do {
            try? fileManager.removeItem(at: partial)
            try fileManager.copyItem(at: source, to: partial)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
            return true
        } catch {
            try? fileManager.removeItem(at: partial)
            return false
        }
    }

    /// Queues a copy to the NAS for a recording that is only on the Mac.
    func copyToNAS(_ recording: Recording) {
        update(recording.id) {
            $0.pendingNASCopy = true
            $0.removeLocalAfterNASCopy = false
        }
        persist()
        processPendingCopies()
    }

    /// Brings a NAS-only recording back onto the Mac.
    func copyToMac(_ recording: Recording) {
        guard recording.onNAS, !recording.onMac, let source = nasURL(for: recording) else { return }
        let destination = localURL(for: recording)
        busyIDs.insert(recording.id)
        queue.async { [weak self] in
            let copied = Self.copy(source, to: destination)
            DispatchQueue.main.async {
                guard let self else { return }
                if copied {
                    self.update(recording.id) { $0.onMac = true }
                    self.persist()
                }
                self.busyIDs.remove(recording.id)
            }
        }
    }

    // MARK: Editing

    func rename(_ recording: Recording, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(recording.id) { $0.name = trimmed }
        persist()
    }

    /// Removes a recording from the history. The local copy goes to the Trash; the NAS copy is deleted.
    func delete(_ recording: Recording) {
        let local = recording.onMac ? localURL(for: recording) : nil
        let remote = recording.onNAS && nas.isAvailable ? nasURL(for: recording) : nil
        recordings.removeAll { $0.id == recording.id }
        persist()
        queue.async {
            let fileManager = FileManager.default
            if let local {
                if (try? fileManager.trashItem(at: local, resultingItemURL: nil)) == nil {
                    try? fileManager.removeItem(at: local)
                }
            }
            if let remote {
                try? fileManager.removeItem(at: remote)
            }
        }
    }

    /// Selects the file in the Finder. Returns false when no copy is reachable (NAS offline).
    @discardableResult
    func revealInFinder(_ recording: Recording) -> Bool {
        guard let url = accessibleURL(for: recording) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }
}
