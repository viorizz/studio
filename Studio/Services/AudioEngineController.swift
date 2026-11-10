import Accelerate
import AVFoundation
import CoreAudio
import StudioCore

/// Live level of the microphone. Kept in its own object so that only the
/// meter views redraw when it changes (about ten times per second).
final class LevelMeterModel: ObservableObject {
    /// Current level, 0…1 on the meter scale.
    @Published private(set) var level: Double = 0
    /// Loudest level of the last moments, used for the verdict text.
    @Published private(set) var heldPeak: Double = 0
    /// The signal hit full scale recently.
    @Published private(set) var clipped = false

    private var heldAt: TimeInterval = 0
    private var clippedAt: TimeInterval = -10

    var voiceLevel: VoiceLevel {
        LevelMath.voiceLevel(heldPeak: heldPeak, clipped: clipped)
    }

    /// Called from the audio tap thread.
    func push(peak: Float) {
        let position = LevelMath.position(fromLinear: peak)
        let isClipping = peak >= 0.985
        DispatchQueue.main.async { [weak self] in
            self?.apply(position: position, isClipping: isClipping)
        }
    }

    private func apply(position: Double, isClipping: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        level = position
        if position >= heldPeak || now - heldAt > 1.5 {
            heldPeak = position
            heldAt = now
        }
        if isClipping { clippedAt = now }
        let nowClipped = now - clippedAt < 2
        if nowClipped != clipped { clipped = nowClipped }
    }

    func reset() {
        level = 0
        heldPeak = 0
        clipped = false
        clippedAt = -10
    }
}

/// Recent levels drawn as a waveform while recording.
final class WaveformModel: ObservableObject {
    static let capacity = 64
    @Published private(set) var samples: [Double] = []

    func push(peak: Float) {
        let position = LevelMath.position(fromLinear: peak)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.samples.append(position)
            if self.samples.count > Self.capacity {
                self.samples.removeFirst(self.samples.count - Self.capacity)
            }
        }
    }

    func reset() {
        samples = []
    }
}

enum MonitorState: Equatable {
    /// The user does not want to hear themselves.
    case off
    /// The processed microphone is played to the output device.
    case on
    /// Output and input are the same device (headphones plugged into the microphone):
    /// the microphone already plays the voice back with no delay.
    case hardware
    /// Sound would come out of the Mac speakers and feed back.
    case blockedBySpeakers
}

enum AudioEngineError: LocalizedError {
    case notRunning
    case cannotCreateFile(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Le micro n'est pas prêt. Vérifiez qu'il est branché, puis réessayez."
        case .cannotCreateFile(let reason):
            return "Impossible de créer le fichier d'enregistrement (\(reason))."
        }
    }
}

/// Owns the AVAudioEngine: captures the selected microphone, measures its
/// level, optionally plays it back in the headphones, and writes it to disk.
///
/// The tap callback runs on an AVFoundation queue (not the real-time thread),
/// so encoding and file writes happen there and never on the main thread.
final class AudioEngineController: ObservableObject {
    struct Configuration {
        var device: AudioInputDevice
        var gain: Double
        var noiseReduction: Double
        var monitoring: Bool
        var monitorVolume: Double
    }

    let meter = LevelMeterModel()
    let waveform = WaveformModel()

    @Published private(set) var isRunning = false
    @Published private(set) var monitorState: MonitorState = .off
    @Published private(set) var hasHardwareGain = false

    /// Called on the main queue when the device changed under the engine
    /// (unplugged, sample rate changed): the engine has stopped and must be restarted.
    var onConfigurationChange: (() -> Void)?

    private(set) var device: AudioInputDevice?
    private var engine: AVAudioEngine?
    private var monitorMixer: AVAudioMixerNode?
    private var configObserver: NSObjectProtocol?
    private var format: AVAudioFormat?

    // State shared with the tap queue, guarded by `lock`.
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var isWriting = false
    private var isPaused = false
    private var framesWritten: AVAudioFramePosition = 0
    private var writeFailed = false
    private var softwareGain: Float = 1
    private var gate = NoiseGate(sampleRate: 48000)

    deinit {
        stop()
    }

    // MARK: Engine lifecycle

    /// Starts (or restarts) capture on a device. Returns false when the device can't be opened.
    @discardableResult
    func start(_ configuration: Configuration) -> Bool {
        stop()

        // A fresh engine per configuration: reusing one across device changes keeps stale formats.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let unit = input.audioUnit {
            var deviceID = configuration.device.id
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr { return false }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }

        lock.lock()
        gate = NoiseGate(sampleRate: format.sampleRate, amount: Float(configuration.noiseReduction))
        lock.unlock()

        var state = MonitorState.off
        if configuration.monitoring {
            let output = CoreAudioHelper.defaultOutputDevice()
            if output == configuration.device.id {
                state = .hardware
            } else if let output, CoreAudioHelper.isBuiltInSpeaker(output) {
                state = .blockedBySpeakers
            } else if output != nil {
                let mixer = AVAudioMixerNode()
                engine.attach(mixer)
                engine.connect(input, to: mixer, format: format)
                engine.connect(mixer, to: engine.mainMixerNode, format: format)
                mixer.outputVolume = Float(configuration.monitorVolume)
                monitorMixer = mixer
                state = .on
            }
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            monitorMixer = nil
            return false
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }

        self.engine = engine
        self.format = format
        self.device = configuration.device
        monitorState = state
        isRunning = true
        setGain(configuration.gain)
        return true
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        monitorMixer = nil
        format = nil
        device = nil
        if isRunning { isRunning = false }
        if monitorState != .off { monitorState = .off }
        meter.reset()
    }

    /// After a configuration change (for example headphones plugged in), tries to
    /// keep going with the same engine so that a recording in progress is not cut.
    /// Only possible when the microphone still delivers the same format.
    func resumeAfterConfigurationChange() -> Bool {
        guard let engine, let format else { return false }
        let current = engine.inputNode.outputFormat(forBus: 0)
        guard current.sampleRate == format.sampleRate, current.channelCount == format.channelCount else {
            return false
        }
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    // MARK: Live settings

    /// Microphone volume, 0…1. Uses the device's own input volume when it has one
    /// (best quality, it acts before the signal is digitised or at the driver),
    /// otherwise a software gain of ±12 dB.
    func setGain(_ value: Double) {
        guard let device else { return }
        let hardware = CoreAudioHelper.setInputVolume(device.id, value)
        if hardware != hasHardwareGain { hasHardwareGain = hardware }
        lock.lock()
        softwareGain = hardware ? 1 : SoftwareGain.linear(forSlider: value)
        lock.unlock()
    }

    func setNoiseReduction(_ value: Double) {
        lock.lock()
        gate.amount = Float(value)
        lock.unlock()
    }

    func setMonitorVolume(_ value: Double) {
        monitorMixer?.outputVolume = Float(min(1, max(0, value)))
    }

    // MARK: Recording

    func beginRecording(to url: URL) throws {
        guard isRunning, let format else { throw AudioEngineError.notRunning }
        let channels = Int(format.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 96_000 * min(2, channels)
        ]
        let newFile: AVAudioFile
        do {
            newFile = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioEngineError.cannotCreateFile(error.localizedDescription)
        }
        waveform.reset()
        lock.lock()
        file = newFile
        framesWritten = 0
        writeFailed = false
        isPaused = false
        isWriting = true
        lock.unlock()
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        isPaused = paused
        lock.unlock()
    }

    /// Closes the file. Returns the recorded duration and whether a write error occurred.
    @discardableResult
    func endRecording() -> (duration: TimeInterval, failed: Bool) {
        lock.lock()
        let frames = framesWritten
        let failed = writeFailed
        let rate = file?.processingFormat.sampleRate ?? 48000
        isWriting = false
        isPaused = false
        file = nil // releasing the AVAudioFile finalises the .m4a
        lock.unlock()
        return (Double(frames) / rate, failed)
    }

    // MARK: Tap

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let length = vDSP_Length(frameCount)
        var channels: [UnsafeMutablePointer<Float>] = []
        channels.reserveCapacity(Int(buffer.format.channelCount))
        for index in 0..<Int(buffer.format.channelCount) {
            channels.append(data[index])
        }

        lock.lock()
        if softwareGain != 1 {
            var gain = softwareGain
            for channel in channels {
                vDSP_vsmul(channel, 1, &gain, channel, 1, length)
            }
        }
        gate.process(channels, frameCount: frameCount)

        var peak: Float = 0
        for channel in channels {
            var channelPeak: Float = 0
            vDSP_maxmgv(channel, 1, &channelPeak, length)
            peak = max(peak, channelPeak)
        }

        let recording = isWriting && !isPaused
        if recording, let file {
            do {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(frameCount)
            } catch {
                writeFailed = true
            }
        }
        lock.unlock()

        meter.push(peak: peak)
        if recording {
            waveform.push(peak: peak)
        }
    }
}

/// Records a few seconds through the real pipeline and plays them back,
/// so the user hears exactly what a recording will sound like.
final class MicTester: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle
        case recording
        case playing
    }

    static let duration: TimeInterval = 5

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var startedAt = Date()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("studio-essai.m4a")

    func run(with audio: AudioEngineController) {
        guard phase == .idle else { return }
        try? FileManager.default.removeItem(at: url)
        do {
            try audio.beginRecording(to: url)
        } catch {
            return
        }
        phase = .recording
        progress = 0
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak audio] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.startedAt)
            self.progress = min(1, elapsed / Self.duration)
            if elapsed >= Self.duration {
                self.timer?.invalidate()
                self.timer = nil
                audio?.endRecording()
                self.play()
            }
        }
    }

    private func play() {
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            phase = .idle
            return
        }
        player.delegate = self
        self.player = player
        phase = .playing
        player.play()
    }

    func cancel(audio: AudioEngineController) {
        timer?.invalidate()
        timer = nil
        if phase == .recording {
            audio.endRecording()
        }
        player?.stop()
        player = nil
        phase = .idle
        progress = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.player = nil
            self?.phase = .idle
            self?.progress = 0
        }
    }
}
