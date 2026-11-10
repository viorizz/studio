import Foundation

public struct RecordingSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public var recordings: [Recording]
}

public enum LibraryGrouping {
    /// Groups recordings (newest first) under "Aujourd'hui", "Hier", "Cette semaine", then by month.
    public static func sections(
        for recordings: [Recording],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [RecordingSection] {
        let sorted = recordings.sorted { $0.date > $1.date }
        var sections: [RecordingSection] = []
        for recording in sorted {
            let (id, title) = sectionKey(for: recording.date, now: now, calendar: calendar)
            if let last = sections.indices.last, sections[last].id == id {
                sections[last].recordings.append(recording)
            } else {
                sections.append(RecordingSection(id: id, title: title, recordings: [recording]))
            }
        }
        return sections
    }

    static func daysAgo(_ date: Date, now: Date, calendar: Calendar) -> Int {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    static func sectionKey(for date: Date, now: Date, calendar: Calendar) -> (id: String, title: String) {
        let days = daysAgo(date, now: now, calendar: calendar)
        if days <= 0 { return ("today", "Aujourd'hui") }
        if days == 1 { return ("yesterday", "Hier") }
        if days < 7 { return ("week", "Cette semaine") }
        let c = calendar.dateComponents([.year, .month], from: date)
        let title = FrenchText.formatter("LLLL yyyy", calendar: calendar).string(from: date)
        return ("\(c.year ?? 0)-\(c.month ?? 0)", FrenchText.capitalizedFirst(title))
    }

    /// "09:14" for today and yesterday, "Mardi 3 novembre" for older recordings
    /// (with the year when it differs from the current one).
    public static func dateLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = daysAgo(date, now: now, calendar: calendar)
        if days <= 1 {
            return FrenchText.formatter("HH:mm", calendar: calendar).string(from: date)
        }
        let weekday = FrenchText.formatter("EEEE", calendar: calendar).string(from: date)
        var label = FrenchText.capitalizedFirst(weekday) + " " + FrenchText.dayAndMonth(date, calendar: calendar)
        let year = calendar.component(.year, from: date)
        if year != calendar.component(.year, from: now) {
            label += " \(year)"
        }
        return label
    }

    /// Case- and accent-insensitive search on the display name and the file name.
    public static func filter(_ recordings: [Recording], query: String) -> [Recording] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return recordings }
        return recordings.filter {
            fold($0.name).contains(needle) || fold($0.fileName).contains(needle)
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: FrenchText.locale)
    }
}

/// JSON persistence of the history.
public enum LibraryFile {
    public static func load(from url: URL) -> [Recording] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Recording].self, from: data)) ?? []
    }

    public static func save(_ recordings: [Recording], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recordings)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
