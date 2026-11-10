import AppKit
import StudioCore
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// A colour with a light and a dark variant.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// The record red, same as the system recording apps.
    static let recordRed = Color(nsColor: .systemRed)
}

extension LevelZone {
    /// Fill colour for tracks and meters.
    var fill: Color {
        switch self {
        case .green: return Color(nsColor: .systemGreen)
        case .orange: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        }
    }

    /// Text colour: darker than the fill so it stays readable on a light background.
    var text: Color {
        switch self {
        case .green: return .adaptive(light: 0x1E7B34, dark: 0x30D158)
        case .orange: return .adaptive(light: 0xA84A00, dark: 0xFF9F0A)
        case .red: return .adaptive(light: 0xC4271D, dark: 0xFF6961)
        }
    }
}

/// A short judgement shown next to a meter or a slider.
struct Verdict: Equatable {
    let text: String
    let zone: LevelZone?

    var color: Color {
        zone?.text ?? .secondary
    }
}

enum Verdicts {
    static let meterBands = [
        ZoneBand(upperBound: LevelMath.orangeStart, zone: .green),
        ZoneBand(upperBound: LevelMath.redStart, zone: .orange),
        ZoneBand(upperBound: 1, zone: .red)
    ]

    static func voice(_ level: VoiceLevel) -> Verdict {
        switch level {
        case .silent: return Verdict(text: "Parlez pour tester", zone: nil)
        case .tooLow: return Verdict(text: "Trop faible", zone: .orange)
        case .ideal: return Verdict(text: "Idéal", zone: .green)
        case .loud: return Verdict(text: "Un peu fort", zone: .orange)
        case .clipping: return Verdict(text: "Saturé", zone: .red)
        }
    }

    private static func verdict(_ value: Double, _ bands: [ZoneBand], _ texts: [String]) -> Verdict {
        let index = SliderZones.bandIndex(of: value, in: bands)
        return Verdict(text: texts[min(index, texts.count - 1)], zone: bands[index].zone)
    }

    static func gain(_ value: Double) -> Verdict {
        verdict(value, SliderZones.gain, ["Trop faible", "Idéal", "Un peu fort", "Saturé"])
    }

    static func noiseReduction(_ value: Double) -> Verdict {
        verdict(value, SliderZones.noiseReduction, ["Naturel", "Forte", "Voix déformée"])
    }

    static func monitorVolume(_ value: Double) -> Verdict {
        verdict(value, SliderZones.monitorVolume, ["Confortable", "Fort", "Trop fort"])
    }
}
