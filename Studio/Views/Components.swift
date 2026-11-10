import AVFoundation
import StudioCore
import SwiftUI

/// A horizontal bar split into coloured zones.
struct ZoneTrack: View {
    let bands: [ZoneBand]

    var body: some View {
        Canvas { context, size in
            var start = 0.0
            for band in bands {
                let rect = CGRect(
                    x: size.width * start,
                    y: 0,
                    width: size.width * (band.upperBound - start),
                    height: size.height
                )
                context.fill(Path(rect), with: .color(band.zone.fill))
                start = band.upperBound
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Live level of the microphone on a green / orange / red scale.
struct LevelMeterView: View {
    @ObservedObject var meter: LevelMeterModel
    var height: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ZoneTrack(bands: Verdicts.meterBands)
                    .opacity(0.22)
                ZoneTrack(bands: Verdicts.meterBands)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: geometry.size.width * meter.level)
                    }
                    .animation(.linear(duration: 0.1), value: meter.level)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Niveau du micro")
        .accessibilityValue(Verdicts.voice(meter.voiceLevel).text)
    }
}

/// Text verdict for the voice level ("Idéal", "Saturé"…).
struct VoiceVerdictText: View {
    @ObservedObject var meter: LevelMeterModel

    var body: some View {
        let verdict = Verdicts.voice(meter.voiceLevel)
        Text(verdict.text)
            .fontWeight(.semibold)
            .foregroundColor(verdict.color)
    }
}

/// A slider whose track shows where the good and bad ranges are.
struct ZoneSlider: View {
    let label: String
    @Binding var value: Double
    let bands: [ZoneBand]
    var onEditingEnded: () -> Void = {}

    @Environment(\.isEnabled) private var isEnabled
    private let thumb: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - thumb)
            ZStack(alignment: .leading) {
                ZoneTrack(bands: bands)
                    .frame(height: 6)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: travel * value)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = min(1, max(0, (gesture.location.x - thumb / 2) / travel))
                    }
                    .onEnded { _ in onEditingEnded() }
            )
        }
        .frame(height: 28)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
            onEditingEnded()
        }
    }
}

/// A labelled zone slider with its verdict on the right.
struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let bands: [ZoneBand]
    let verdict: Verdict
    var onEditingEnded: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Text(verdict.text)
                    .fontWeight(.semibold)
                    .foregroundColor(verdict.color)
            }
            .font(.system(size: 14))
            ZoneSlider(label: title, value: $value, bands: bands, onEditingEnded: onEditingEnded)
        }
    }
}

/// The recent sound drawn as vertical bars while recording.
struct WaveformView: View {
    @ObservedObject var waveform: WaveformModel
    var color: Color = .recordRed

    var body: some View {
        Canvas { context, size in
            let capacity = WaveformModel.capacity
            let step = size.width / CGFloat(capacity)
            let barWidth = max(2, step * 0.45)
            let samples = waveform.samples
            let offset = capacity - samples.count
            for index in 0..<capacity {
                let level = index >= offset ? samples[index - offset] : 0
                let barHeight = max(4, size.height * CGFloat(level))
                let rect = CGRect(
                    x: CGFloat(index) * step + (step - barWidth) / 2,
                    y: (size.height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(index >= offset ? color : Color.secondary.opacity(0.3)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The big round button: a red disc to start, a red square to stop.
struct RecordButton: View {
    enum Symbol {
        case record
        case stop
    }

    let symbol: Symbol
    var diameter: CGFloat = 184
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: diameter * 0.028)
                switch symbol {
                case .record:
                    Circle()
                        .fill(Color.recordRed)
                        .padding(diameter * 0.1)
                case .stop:
                    RoundedRectangle(cornerRadius: diameter * 0.09, style: .continuous)
                        .fill(Color.recordRed)
                        .frame(width: diameter * 0.38, height: diameter * 0.38)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// "Mac" / "NAS" pill showing where a recording is stored.
struct StorageBadge: View {
    enum Kind {
        case mac
        case nas
        case nasPending
    }

    let kind: Kind
    var onSelection = false

    private var title: String {
        switch kind {
        case .mac: return "Mac"
        case .nas: return "NAS"
        case .nasPending: return "NAS en attente"
        }
    }

    private var icon: String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .nas: return "externaldrive.connected.to.line.below"
        case .nasPending: return "clock"
        }
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(onSelection ? Color.accentColor : .primary)
            .background(
                Capsule().fill(onSelection ? Color.white : Color.primary.opacity(kind == .mac ? 0.08 : 0.14))
            )
            .accessibilityLabel(kind == .nasPending ? "Copie sur le NAS en attente" : "Enregistré sur le \(title)")
    }
}

/// Live camera picture.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }
}

final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        root.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Progress pills + "Étape n sur 4", bottom left of the setup assistant.
struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 28, height: 6)
                }
            }
            .accessibilityHidden(true)
            Text("Étape \(current + 1) sur \(total)")
                .foregroundColor(.secondary)
        }
    }
}
