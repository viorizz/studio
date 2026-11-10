import Foundation

public enum FrenchText {
    public static let locale = Locale(identifier: "fr_FR")

    public static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// "1er novembre", "10 novembre".
    static func dayAndMonth(_ date: Date, calendar: Calendar) -> String {
        let day = calendar.component(.day, from: date)
        let month = formatter("MMMM", calendar: calendar).string(from: date)
        return (day == 1 ? "1er" : String(day)) + " " + month
    }
}

public enum RecordingNamer {
    /// Sortable name used on disk, e.g. "2026-11-10 09.14 Audio.m4a".
    public static func fileName(date: Date, kind: RecordingKind, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d %02d.%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0
        )
        return "\(stamp) \(kind.label).\(kind.fileExtension)"
    }

    /// Readable name proposed in the app, e.g. "Enregistrement du 10 novembre à 09:14".
    public static func defaultName(date: Date, kind: RecordingKind, calendar: Calendar = .current) -> String {
        let day = FrenchText.dayAndMonth(date, calendar: calendar)
        let time = FrenchText.formatter("HH:mm", calendar: calendar).string(from: date)
        let prefix = kind == .audio ? "Enregistrement" : "Vidéo"
        return "\(prefix) du \(day) à \(time)"
    }

    /// Returns `fileName`, or "name 2.ext", "name 3.ext"… until `exists` says the name is free.
    public static func uniqueFileName(_ fileName: String, exists: (String) -> Bool) -> String {
        guard exists(fileName) else { return fileName }
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !exists(candidate) { return candidate }
            index += 1
        }
    }
}

public enum DurationText {
    /// "38 s", "2 min 47 s", "1 h 05 min".
    public static func spoken(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d h %02d min", hours, minutes) }
        if minutes > 0 { return String(format: "%d min %02d s", minutes, seconds) }
        return "\(seconds) s"
    }

    /// "00:02:47", used by the recording timer.
    public static func clock(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "2:47", used by the player.
    public static func short(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
