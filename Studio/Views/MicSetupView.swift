import StudioCore
import SwiftUI

/// The four-step microphone assistant: plug in → choose → adjust while listening → ready.
struct MicSetupView: View {
    let initialStep: Int

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var devices: AudioDeviceMonitor
    @EnvironmentObject private var audio: AudioEngineController
    @EnvironmentObject private var recorder: RecorderCoordinator
    @EnvironmentObject private var navigation: Navigation

    @State private var step = 0
    @State private var chosenUID: String?
    @State private var alwaysUse = true
    @StateObject private var tester = MicTester()

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: plugStep
                case 1: chooseStep
                case 2:
                    if recorder.microphoneDenied {
                        PermissionNotice(
                            icon: "mic.slash",
                            title: "Studio n'a pas accès au micro",
                            message: "Autorisez Studio dans Réglages Système › Confidentialité et sécurité › Micro, puis revenez ici.",
                            mediaType: .audio
                        )
                    } else {
                        adjustStep
                    }
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .onAppear {
            step = min(max(0, initialStep), stepCount - 1)
            alwaysUse = settings.autoUsePreferredMic
            chosenUID = devices.suggestedExternal?.uid ?? devices.selectedUID
            recorder.activate()
        }
        .onChange(of: devices.devices) { _ in
            // A microphone was plugged in or removed while the assistant is open.
            if chosenUID == nil || !devices.devices.contains(where: { $0.uid == chosenUID }) {
                chosenUID = devices.suggestedExternal?.uid ?? devices.selectedUID
            }
        }
        .onDisappear {
            tester.cancel(audio: audio)
        }
    }

    private var chosenDevice: AudioInputDevice? {
        devices.devices.first { $0.uid == chosenUID }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            StepIndicator(current: step, total: stepCount)
            Spacer()
            if step == stepCount - 1 {
                Button("Modifier les réglages") { step = 2 }
                    .controlSize(.large)
            } else {
                Button(step == 0 ? "Annuler" : "Retour") {
                    if step == 0 {
                        close()
                    } else {
                        tester.cancel(audio: audio)
                        step -= 1
                    }
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                Button("Continuer") { advance() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .background(Color.primary.opacity(0.03))
    }

    private var canContinue: Bool {
        switch step {
        case 0: return !devices.externalDevices.isEmpty
        case 1: return chosenDevice != nil
        default: return audio.isRunning
        }
    }

    private func advance() {
        switch step {
        case 1:
            guard let uid = chosenUID else { return }
            settings.preferredMicUID = uid
            settings.autoUsePreferredMic = alwaysUse
            devices.select(uid)
            recorder.restartCapture()
        case 2:
            tester.cancel(audio: audio)
            if let uid = devices.selectedUID {
                settings.markConfigured(uid)
            }
        default:
            break
        }
        step += 1
    }

    private func close() {
        tester.cancel(audio: audio)
        navigation.tab = .record
        navigation.route = .main
    }

    // MARK: Step 1 — plug in

    private var plugStep: some View {
        VStack(spacing: 22) {
            HStack(spacing: 18) {
                Image(systemName: "mic.fill")
                Image(systemName: "cable.connector")
                    .foregroundColor(.accentColor)
                Image(systemName: "laptopcomputer")
            }
            .font(.system(size: 60, weight: .light))
            .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Branchez votre micro")
                    .font(.system(size: 28, weight: .bold))
                Text("Reliez le câble USB du micro à votre Mac. Sur un Blue Yeti, le bouton rond à l'avant s'allume en rouge dès qu'il est alimenté.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Group {
                if let external = devices.suggestedExternal {
                    Label("\(external.name) détecté", systemImage: "checkmark.circle.fill")
                        .foregroundColor(LevelZone.green.text)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("En attente du micro…")
                    }
                    .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 80)
    }

    // MARK: Step 2 — choose the input

    private var chooseStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Text("Choisissez le micro à utiliser")
                    .font(.system(size: 28, weight: .bold))
                Text("Studio enregistrera votre voix avec le micro sélectionné ci-dessous. Vous n'avez rien à changer dans les réglages du Mac.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(spacing: 0) {
                ForEach(Array(devices.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Divider() }
                    deviceRow(device)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(width: 520)

            Toggle("Toujours utiliser \(chosenDevice?.name ?? "ce micro") quand il est branché", isOn: $alwaysUse)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 80)
    }

    private func deviceRow(_ device: AudioInputDevice) -> some View {
        let isChosen = device.uid == chosenUID
        return Button {
            chosenUID = device.uid
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isChosen ? .accentColor : .secondary)
                Image(systemName: device.isBuiltIn ? "laptopcomputer" : "mic")
                    .font(.system(size: 20))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(device.isBuiltIn ? "Intégré · son moins net" : "Micro externe")
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !device.isBuiltIn, device.uid == devices.suggestedExternal?.uid {
                    Text("Recommandé")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
            .background(isChosen ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    // MARK: Step 3 — adjust while listening

    private var gainBinding: Binding<Double> {
        Binding(
            get: {
                guard let device = devices.selected else { return 0.5 }
                return settings.micGains[device.uid] ?? CoreAudioHelper.inputVolume(device.id) ?? 0.5
            },
            set: { newValue in
                guard let device = devices.selected else { return }
                settings.micGains[device.uid] = newValue
                audio.setGain(newValue)
            }
        )
    }

    private var noiseBinding: Binding<Double> {
        Binding(
            get: { settings.noiseReduction },
            set: { newValue in
                settings.noiseReduction = newValue
                audio.setNoiseReduction(newValue)
            }
        )
    }

    private var monitorVolumeBinding: Binding<Double> {
        Binding(
            get: { settings.monitorVolume },
            set: { newValue in
                settings.monitorVolume = newValue
                audio.setMonitorVolume(newValue)
            }
        )
    }

    private var monitoringBinding: Binding<Bool> {
        Binding(
            get: { settings.monitoringEnabled },
            set: { newValue in
                settings.monitoringEnabled = newValue
                tester.cancel(audio: audio)
                recorder.restartCapture()
            }
        )
    }

    private var adjustStep: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Réglez le son en vous écoutant")
                        .font(.system(size: 24, weight: .bold))
                    Text("Parlez normalement et déplacez les curseurs. L'objectif : rester dans le vert.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Niveau de votre voix")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        VoiceVerdictText(meter: audio.meter)
                            .font(.system(size: 14))
                    }
                    LevelMeterView(meter: audio.meter)
                    HStack(spacing: 18) {
                        legend(.green, "Vert : parfait")
                        legend(.orange, "Orange : attention")
                        legend(.red, "Rouge : le son sature")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))

                SettingSlider(
                    title: "Volume du micro",
                    value: gainBinding,
                    bands: SliderZones.gain,
                    verdict: Verdicts.gain(gainBinding.wrappedValue)
                )
                SettingSlider(
                    title: "Réduction du bruit de fond",
                    value: noiseBinding,
                    bands: SliderZones.noiseReduction,
                    verdict: Verdicts.noiseReduction(settings.noiseReduction)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("M'écouter dans le casque", isOn: monitoringBinding)
                        .font(.system(size: 14, weight: .semibold))
                    if let note = monitoringNote {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if audio.monitorState == .on {
                        SettingSlider(
                            title: "Volume dans le casque",
                            value: monitorVolumeBinding,
                            bands: SliderZones.monitorVolume,
                            verdict: Verdicts.monitorVolume(settings.monitorVolume)
                        )
                        .padding(.top, 4)
                    }
                }

                testRow
            }
            .frame(maxWidth: 580)

            tipsCard
                .frame(width: 250)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .onAppear {
            if !audio.isRunning { recorder.restartCapture() }
        }
    }

    private func legend(_ zone: LevelZone, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(zone.fill)
                .frame(width: 10, height: 10)
            Text(text)
        }
    }

    private var monitoringNote: String? {
        guard settings.monitoringEnabled else {
            return "Branchez un casque, puis activez cette option pour entendre votre voix pendant les réglages."
        }
        switch audio.monitorState {
        case .hardware:
            return "Votre casque est branché sur le micro : il vous fait déjà entendre votre voix en direct. Le volume se règle avec la molette du micro."
        case .blockedBySpeakers:
            return "Branchez un casque pour vous écouter : avec les haut-parleurs du Mac, le son se mettrait à siffler."
        case .on:
            return "Vous entendez le volume réglé ci-dessus. La réduction du bruit s'entend dans l'essai de 5 secondes."
        case .off:
            return nil
        }
    }

    private var testRow: some View {
        HStack(spacing: 12) {
            Button {
                if tester.phase == .idle {
                    tester.run(with: audio)
                } else {
                    tester.cancel(audio: audio)
                }
            } label: {
                switch tester.phase {
                case .idle: Label("Faire un essai de 5 secondes", systemImage: "play.fill")
                case .recording: Label("Parlez… (arrêter)", systemImage: "stop.fill")
                case .playing: Label("Écoute de l'essai… (arrêter)", systemImage: "stop.fill")
                }
            }
            .controlSize(.large)
            .disabled(!audio.isRunning)

            if tester.phase == .recording {
                ProgressView(value: tester.progress)
                    .frame(width: 120)
            } else if tester.phase == .idle {
                Text("Studio enregistre, puis vous fait réécouter votre voix.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tipsCard: some View {
        let isYeti = devices.selected?.isYeti ?? false
        return VStack(alignment: .leading, spacing: 14) {
            Text("À vérifier sur le micro")
                .font(.system(size: 15, weight: .bold))
            if isYeti {
                tip("Molette PATTERN, au dos", "Sur le symbole en forme de cœur : le micro n'écoute que devant lui.")
                tip("Molette GAIN, au dos", "Au milieu. Le réglage fin se fait ici, à l'écran.")
                tip("Position", "Parlez face au logo Blue, pas au-dessus du micro.")
            } else {
                tip("Position", "Parlez face au micro, sans le toucher pendant l'enregistrement.")
            }
            tip("Distance", "Environ 15 à 20 cm, soit une main ouverte.")
            if !audio.hasHardwareGain, audio.isRunning {
                tip("Volume", "Ce micro n'a pas de volume réglable par le Mac : Studio ajuste le son lui-même.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func tip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.semibold)
            Text(text)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 4 — ready

    private var readyStep: some View {
        VStack(spacing: 18) {
            ReadyCheckmark()

            VStack(spacing: 10) {
                Text("Votre micro est prêt")
                    .font(.system(size: 30, weight: .bold))
                Text("Vos réglages sont mémorisés. La prochaine fois, il suffira de brancher le micro et d'ouvrir Studio.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            if let device = devices.selected {
                Label("\(device.name) sélectionné", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LevelZone.green.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(LevelZone.green.fill.opacity(0.15)))
            }

            Button {
                close()
            } label: {
                Text("Commencer à enregistrer")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
        }
        .padding(.horizontal, 80)
    }
}

/// The little animation that says "you're good to go": the disc pops, the tick draws itself, a ring expands.
private struct ReadyCheckmark: View {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(LevelZone.green.fill, lineWidth: 3)
                .frame(width: 104, height: 104)
                .scaleEffect(shown ? 1.5 : 0.7)
                .opacity(shown ? 0 : 0.6)
                .animation(reduceMotion ? nil : .easeOut(duration: 1.4).delay(0.45), value: shown)
            Circle()
                .fill(LevelZone.green.fill)
                .frame(width: 104, height: 104)
                .scaleEffect(shown ? 1 : 0.4)
                .opacity(shown ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: shown)
            CheckShape()
                .trim(from: 0, to: shown ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                .frame(width: 46, height: 34)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.4), value: shown)
        }
        .frame(width: 160, height: 160)
        .onAppear { shown = true }
        .accessibilityHidden(true)
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
