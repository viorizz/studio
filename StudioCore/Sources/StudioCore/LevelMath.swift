import Foundation

/// Colour of a zone on a meter or a slider.
public enum LevelZone: Equatable, Sendable {
    case green
    case orange
    case red
}

/// What the voice level currently means for the user.
public enum VoiceLevel: Equatable, Sendable {
    case silent
    case tooLow
    case ideal
    case loud
    case clipping
}

public enum LevelMath {
    /// Bottom of the meter, in dBFS.
    public static let floorDB: Float = -60

    /// Meter positions (0…1) where the zones change. With a -60 dB floor these
    /// are -18 dBFS and -9 dBFS: comfortable headroom for speech.
    public static let orangeStart = 0.70
    public static let redStart = 0.85
    public static let tooLowEnd = 0.35
    public static let silentEnd = 0.08

    public static func decibels(fromLinear value: Float) -> Float {
        guard value > 0 else { return floorDB }
        return max(floorDB, 20 * log10(value))
    }

    /// Maps dBFS to a 0…1 position on the meter (linear in dB).
    public static func position(fromDecibels db: Float) -> Double {
        let clamped = min(0, max(floorDB, db))
        return Double(1 - clamped / floorDB)
    }

    public static func position(fromLinear value: Float) -> Double {
        position(fromDecibels: decibels(fromLinear: value))
    }

    public static func zone(atPosition position: Double) -> LevelZone {
        if position >= redStart { return .red }
        if position >= orangeStart { return .orange }
        return .green
    }

    /// Verdict for the loudest recent level (a held peak, so pauses between words don't count).
    public static func voiceLevel(heldPeak: Double, clipped: Bool) -> VoiceLevel {
        if clipped || heldPeak >= redStart { return .clipping }
        if heldPeak >= orangeStart { return .loud }
        if heldPeak >= tooLowEnd { return .ideal }
        if heldPeak >= silentEnd { return .tooLow }
        return .silent
    }
}

/// A coloured band of a slider, ending at `upperBound` (0…1).
public struct ZoneBand: Equatable, Sendable {
    public let upperBound: Double
    public let zone: LevelZone

    public init(upperBound: Double, zone: LevelZone) {
        self.upperBound = upperBound
        self.zone = zone
    }
}

public enum SliderZones {
    /// Microphone volume: too low and too high are both bad.
    public static let gain = [
        ZoneBand(upperBound: 0.30, zone: .orange),
        ZoneBand(upperBound: 0.70, zone: .green),
        ZoneBand(upperBound: 0.85, zone: .orange),
        ZoneBand(upperBound: 1.00, zone: .red)
    ]

    /// Noise reduction: too much makes the voice sound chopped.
    public static let noiseReduction = [
        ZoneBand(upperBound: 0.60, zone: .green),
        ZoneBand(upperBound: 0.85, zone: .orange),
        ZoneBand(upperBound: 1.00, zone: .red)
    ]

    /// Headphone volume: protect the ears.
    public static let monitorVolume = [
        ZoneBand(upperBound: 0.70, zone: .green),
        ZoneBand(upperBound: 0.90, zone: .orange),
        ZoneBand(upperBound: 1.00, zone: .red)
    ]

    /// Index of the band containing `value` (0…1).
    public static func bandIndex(of value: Double, in bands: [ZoneBand]) -> Int {
        for (index, band) in bands.enumerated() where value <= band.upperBound {
            return index
        }
        return max(0, bands.count - 1)
    }

    public static func zone(of value: Double, in bands: [ZoneBand]) -> LevelZone {
        guard !bands.isEmpty else { return .green }
        return bands[bandIndex(of: value, in: bands)].zone
    }
}

/// Software gain used when the device has no adjustable input volume:
/// the slider (0…1) maps to -12…+12 dB, 0.5 being unity.
public enum SoftwareGain {
    public static func linear(forSlider value: Double) -> Float {
        let db = (min(1, max(0, value)) - 0.5) * 24
        return Float(pow(10, db / 20))
    }
}
