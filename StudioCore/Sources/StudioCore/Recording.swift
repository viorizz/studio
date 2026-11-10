import Foundation

public enum RecordingKind: String, Codable, Sendable {
    case audio
    case video

    public var fileExtension: String {
        switch self {
        case .audio: return "m4a"
        case .video: return "mov"
        }
    }

    public var label: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Vidéo"
        }
    }
}

/// Where the user wants a finished recording to live.
public enum SaveLocation: String, Codable, CaseIterable, Sendable {
    case mac
    case nas
    case both
}

/// One entry of the history. The display `name` is independent from `fileName`
/// so the list stays readable while files keep a sortable, unique name on disk.
public struct Recording: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var fileName: String
    public var date: Date
    public var duration: TimeInterval
    public var kind: RecordingKind
    /// A copy exists in the local Studio folder.
    public var onMac: Bool
    /// A copy exists in the NAS folder.
    public var onNAS: Bool
    /// The file still has to be copied to the NAS (NAS was unreachable, or the copy is queued).
    public var pendingNASCopy: Bool
    /// Once the NAS copy succeeds, the local copy is removed (location "NAS only").
    public var removeLocalAfterNASCopy: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        date: Date,
        duration: TimeInterval,
        kind: RecordingKind,
        onMac: Bool = true,
        onNAS: Bool = false,
        pendingNASCopy: Bool = false,
        removeLocalAfterNASCopy: Bool = false
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.date = date
        self.duration = duration
        self.kind = kind
        self.onMac = onMac
        self.onNAS = onNAS
        self.pendingNASCopy = pendingNASCopy
        self.removeLocalAfterNASCopy = removeLocalAfterNASCopy
    }

    /// Applies the storage flags matching a save location, before any NAS copy has run.
    public mutating func apply(_ location: SaveLocation) {
        onMac = true
        switch location {
        case .mac:
            pendingNASCopy = false
            removeLocalAfterNASCopy = false
        case .nas:
            pendingNASCopy = !onNAS
            removeLocalAfterNASCopy = true
        case .both:
            pendingNASCopy = !onNAS
            removeLocalAfterNASCopy = false
        }
    }

    /// Records the outcome of a NAS copy attempt.
    public mutating func nasCopyFinished(success: Bool) {
        guard success else { return }
        onNAS = true
        pendingNASCopy = false
        if removeLocalAfterNASCopy {
            onMac = false
            removeLocalAfterNASCopy = false
        }
    }
}
