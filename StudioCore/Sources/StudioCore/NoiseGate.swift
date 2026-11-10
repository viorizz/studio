import Foundation

/// A gentle downward expander: when the signal falls under a threshold (room
/// noise between sentences) it is turned down, and it comes back as soon as
/// the voice returns. `amount` 0 leaves the audio untouched.
///
/// All state is plain floats and the loop allocates nothing, so it is safe to
/// run on the audio tap thread.
public struct NoiseGate {
    public var amount: Float {
        didSet { updateTargets() }
    }

    private let attack: Float
    private let release: Float
    private let open: Float
    private let close: Float

    private var threshold: Float = 0
    private var floorGain: Float = 1
    private var envelope: Float = 0
    private var gain: Float = 1

    public init(sampleRate: Double, amount: Float = 0) {
        let rate = Float(max(8000, sampleRate))
        attack = exp(-1 / (0.002 * rate))
        release = exp(-1 / (0.120 * rate))
        open = exp(-1 / (0.005 * rate))
        close = exp(-1 / (0.150 * rate))
        self.amount = amount
        updateTargets()
    }

    private mutating func updateTargets() {
        let a = min(1, max(0, amount))
        // Threshold from -66 dBFS (barely active) to -30 dBFS (aggressive).
        threshold = pow(10, (-66 + 36 * a) / 20)
        // Closed gate attenuation from 0 dB to -36 dB.
        floorGain = pow(10, (-36 * a) / 20)
    }

    /// Current gain applied by the gate (1 = open).
    public var currentGain: Float { gain }

    public mutating func process(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        guard amount > 0, frameCount > 0, !channels.isEmpty else { return }
        var env = envelope
        var g = gain
        for i in 0..<frameCount {
            var peak: Float = 0
            for channel in channels {
                let value = abs(channel[i])
                if value > peak { peak = value }
            }
            let envCoef = peak > env ? attack : release
            env = envCoef * env + (1 - envCoef) * peak

            let target: Float = env >= threshold ? 1 : floorGain
            let gainCoef = target > g ? open : close
            g = gainCoef * g + (1 - gainCoef) * target

            for channel in channels {
                channel[i] *= g
            }
        }
        envelope = env
        gain = g
    }
}
