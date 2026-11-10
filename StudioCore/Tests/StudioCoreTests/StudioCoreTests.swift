import XCTest
@testable import StudioCore

private let zurich: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
    calendar.locale = Locale(identifier: "fr_FR")
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    zurich.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

final class RecordingNamerTests: XCTestCase {
    func testFileNameIsSortableAndTyped() {
        let d = date(2026, 11, 10, 9, 14)
        XCTAssertEqual(RecordingNamer.fileName(date: d, kind: .audio, calendar: zurich), "2026-11-10 09.14 Audio.m4a")
        XCTAssertEqual(RecordingNamer.fileName(date: d, kind: .video, calendar: zurich), "2026-11-10 09.14 Vidéo.mov")
    }

    func testDefaultNameIsReadableFrench() {
        XCTAssertEqual(
            RecordingNamer.defaultName(date: date(2026, 11, 10, 9, 14), kind: .audio, calendar: zurich),
            "Enregistrement du 10 novembre à 09:14"
        )
        XCTAssertEqual(
            RecordingNamer.defaultName(date: date(2026, 11, 1, 16, 5), kind: .video, calendar: zurich),
            "Vidéo du 1er novembre à 16:05"
        )
    }

    func testUniqueFileNameAddsCounter() {
        let taken: Set<String> = ["a.m4a", "a 2.m4a"]
        XCTAssertEqual(RecordingNamer.uniqueFileName("b.m4a") { taken.contains($0) }, "b.m4a")
        XCTAssertEqual(RecordingNamer.uniqueFileName("a.m4a") { taken.contains($0) }, "a 3.m4a")
    }

    func testDurations() {
        XCTAssertEqual(DurationText.spoken(38), "38 s")
        XCTAssertEqual(DurationText.spoken(167), "2 min 47 s")
        XCTAssertEqual(DurationText.spoken(3900), "1 h 05 min")
        XCTAssertEqual(DurationText.clock(167), "00:02:47")
        XCTAssertEqual(DurationText.short(167), "2:47")
        XCTAssertEqual(DurationText.short(3725), "1:02:05")
    }
}

final class RecordingStorageTests: XCTestCase {
    private func make() -> Recording {
        Recording(name: "Test", fileName: "t.m4a", date: date(2026, 11, 10), duration: 10, kind: .audio)
    }

    func testMacOnly() {
        var r = make()
        r.apply(.mac)
        XCTAssertTrue(r.onMac)
        XCTAssertFalse(r.pendingNASCopy)
    }

    func testNASOnlyKeepsLocalCopyUntilTheCopySucceeds() {
        var r = make()
        r.apply(.nas)
        XCTAssertTrue(r.onMac)
        XCTAssertTrue(r.pendingNASCopy)

        r.nasCopyFinished(success: false)
        XCTAssertTrue(r.onMac, "a failed copy must never lose the recording")
        XCTAssertTrue(r.pendingNASCopy)

        r.nasCopyFinished(success: true)
        XCTAssertFalse(r.onMac)
        XCTAssertTrue(r.onNAS)
        XCTAssertFalse(r.pendingNASCopy)
    }

    func testBothKeepsLocalCopy() {
        var r = make()
        r.apply(.both)
        r.nasCopyFinished(success: true)
        XCTAssertTrue(r.onMac)
        XCTAssertTrue(r.onNAS)
    }
}

final class LevelMathTests: XCTestCase {
    func testPositions() {
        XCTAssertEqual(LevelMath.position(fromLinear: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(LevelMath.position(fromLinear: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(LevelMath.position(fromDecibels: -18), 0.70, accuracy: 1e-6)
        XCTAssertEqual(LevelMath.position(fromDecibels: -200), 0, accuracy: 1e-6)
        XCTAssertEqual(LevelMath.position(fromDecibels: 6), 1, accuracy: 1e-6)
    }

    func testZonesAndVerdicts() {
        XCTAssertEqual(LevelMath.zone(atPosition: 0.5), .green)
        XCTAssertEqual(LevelMath.zone(atPosition: 0.75), .orange)
        XCTAssertEqual(LevelMath.zone(atPosition: 0.9), .red)

        XCTAssertEqual(LevelMath.voiceLevel(heldPeak: 0.02, clipped: false), .silent)
        XCTAssertEqual(LevelMath.voiceLevel(heldPeak: 0.2, clipped: false), .tooLow)
        XCTAssertEqual(LevelMath.voiceLevel(heldPeak: 0.55, clipped: false), .ideal)
        XCTAssertEqual(LevelMath.voiceLevel(heldPeak: 0.78, clipped: false), .loud)
        XCTAssertEqual(LevelMath.voiceLevel(heldPeak: 0.55, clipped: true), .clipping)
    }

    func testSliderBands() {
        XCTAssertEqual(SliderZones.zone(of: 0.1, in: SliderZones.gain), .orange)
        XCTAssertEqual(SliderZones.zone(of: 0.5, in: SliderZones.gain), .green)
        XCTAssertEqual(SliderZones.zone(of: 0.8, in: SliderZones.gain), .orange)
        XCTAssertEqual(SliderZones.zone(of: 0.95, in: SliderZones.gain), .red)
        XCTAssertEqual(SliderZones.bandIndex(of: 2, in: SliderZones.gain), 3)
        XCTAssertEqual(SliderZones.zone(of: 0.35, in: SliderZones.noiseReduction), .green)
    }

    func testSoftwareGainIsUnityAtCentre() {
        XCTAssertEqual(SoftwareGain.linear(forSlider: 0.5), 1, accuracy: 1e-5)
        XCTAssertEqual(SoftwareGain.linear(forSlider: 1), 3.981, accuracy: 1e-2)
        XCTAssertEqual(SoftwareGain.linear(forSlider: 0), 0.251, accuracy: 1e-2)
    }
}

final class NoiseGateTests: XCTestCase {
    private func run(_ gate: inout NoiseGate, _ samples: inout [Float]) {
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { buffer in
            gate.process([buffer.baseAddress!], frameCount: count)
        }
    }

    func testBypassWhenAmountIsZero() {
        var gate = NoiseGate(sampleRate: 48000, amount: 0)
        var samples = [Float](repeating: 0.001, count: 4800)
        run(&gate, &samples)
        XCTAssertEqual(samples, [Float](repeating: 0.001, count: 4800))
    }

    func testQuietNoiseIsTurnedDown() {
        var gate = NoiseGate(sampleRate: 48000, amount: 0.5)
        var samples = [Float](repeating: 0.001, count: 48000)
        run(&gate, &samples)
        XCTAssertLessThan(samples.last!, 0.0002)
    }

    func testVoiceLevelPassesUntouched() {
        var gate = NoiseGate(sampleRate: 48000, amount: 0.5)
        var samples = [Float](repeating: 0.3, count: 48000)
        run(&gate, &samples)
        XCTAssertEqual(samples.last!, 0.3, accuracy: 1e-3)
    }

    func testGateReopensWhenVoiceReturns() {
        var gate = NoiseGate(sampleRate: 48000, amount: 0.8)
        var quiet = [Float](repeating: 0.0005, count: 48000)
        run(&gate, &quiet)
        XCTAssertLessThan(gate.currentGain, 0.1)

        var voice = [Float](repeating: 0.3, count: 4800)
        run(&gate, &voice)
        XCTAssertEqual(voice.last!, 0.3, accuracy: 3e-3)
    }
}

final class LibraryGroupingTests: XCTestCase {
    private let now = date(2026, 11, 10, 10, 0)

    private func recording(_ name: String, _ d: Date) -> Recording {
        Recording(name: name, fileName: name + ".m4a", date: d, duration: 60, kind: .audio)
    }

    func testSections() {
        let recordings = [
            recording("vieux", date(2026, 9, 20)),
            recording("matin", date(2026, 11, 10, 9, 14)),
            recording("hier", date(2026, 11, 9, 16, 20)),
            recording("semaine", date(2026, 11, 5)),
            recording("plus tôt", date(2026, 11, 10, 8, 52)),
            recording("octobre", date(2026, 10, 28))
        ]
        let sections = LibraryGrouping.sections(for: recordings, now: now, calendar: zurich)
        XCTAssertEqual(
            sections.map(\.title),
            ["Aujourd'hui", "Hier", "Cette semaine", "Octobre 2026", "Septembre 2026"]
        )
        XCTAssertEqual(sections[0].recordings.map(\.name), ["matin", "plus tôt"])
    }

    func testDateLabels() {
        XCTAssertEqual(LibraryGrouping.dateLabel(for: date(2026, 11, 10, 9, 14), now: now, calendar: zurich), "09:14")
        XCTAssertEqual(LibraryGrouping.dateLabel(for: date(2026, 11, 3), now: now, calendar: zurich), "Mardi 3 novembre")
        XCTAssertEqual(LibraryGrouping.dateLabel(for: date(2026, 11, 1), now: now, calendar: zurich), "Dimanche 1er novembre")
        XCTAssertEqual(LibraryGrouping.dateLabel(for: date(2025, 12, 24), now: now, calendar: zurich), "Mercredi 24 décembre 2025")
    }

    func testSearchIgnoresCaseAndAccents() {
        let recordings = [
            recording("Présentation de la nouvelle offre", now),
            recording("Message d'accueil", now)
        ]
        XCTAssertEqual(LibraryGrouping.filter(recordings, query: "presentation").map(\.name), ["Présentation de la nouvelle offre"])
        XCTAssertEqual(LibraryGrouping.filter(recordings, query: "  ").count, 2)
        XCTAssertEqual(LibraryGrouping.filter(recordings, query: "xyz").count, 0)
    }

    func testIndexRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-tests-\(UUID().uuidString)")
            .appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var original = recording("Essai", date(2026, 11, 10, 9, 14))
        original.apply(.nas)
        try LibraryFile.save([original], to: url)
        XCTAssertEqual(LibraryFile.load(from: url), [original])
        XCTAssertEqual(LibraryFile.load(from: url.appendingPathExtension("missing")), [])
    }
}
