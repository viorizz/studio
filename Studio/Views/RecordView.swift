import AVFoundation
import StudioCore
import SwiftUI

/// The main screen: one big button, nothing in the way.
struct RecordView: View {
    @EnvironmentObject private var recorder: RecorderCoordinator
    @EnvironmentObject private var devices: AudioDeviceMonitor
    @EnvironmentObject private var audio: AudioEngineController
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if recorder.microphoneDenied {
                    PermissionNotice(
                        icon: "mic.slash",
                        title: "Studio n'a pas accès au micro",
                        message: "Autorisez Studio dans Réglages Système › Confidentialité et sécurité › Micro, puis revenez ici.",
                        mediaType: .audio
                    )
                } else if recorder.isBusy {
                    recordingContent
                } else {
                    idleContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusBar()
        }
        .alert(
            "Enregistrement impossible",
            isPresented: Binding(
                get: { recorder.errorMessage != nil },
                set: { if !$0 { recorder.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }

    // MARK: Idle

    private var modePicker: some View {
        Picker("Type d'enregistrement", selection: $recorder.mode) {
            Label("Audio", systemImage: "mic").tag(RecordingKind.audio)
            Label("Vidéo", systemImage: "video").tag(RecordingKind.video)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .frame(width: 220)
    }

    @ViewBuilder
    private var idleContent: some View {
        switch recorder.mode {
        case .audio:
            VStack(spacing: 28) {
                modePicker
                RecordButton(symbol: .record, label: "Démarrer l'enregistrement") {
                    recorder.start()
                }
                .disabled(devices.selected == nil)
                VStack(spacing: 6) {
                    Text("Cliquez pour enregistrer")
                        .font(.system(size: 24, weight: .semibold))
                    Text(idleSubtitle)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
        case .video:
            VStack(spacing: 14) {
                modePicker
                cameraArea
                HStack {
                    cameraMenu
                        .frame(width: 220, alignment: .leading)
                    Spacer()
                    RecordButton(symbol: .record, diameter: 76, label: "Démarrer l'enregistrement vidéo") {
                        recorder.start()
                    }
                    .disabled(!camera.isRunning)
                    Spacer()
                    Text("Cliquez pour filmer")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(width: 220, alignment: .trailing)
                }
                .frame(maxWidth: 620)
            }
            .padding(.vertical, 16)
        }
    }

    private var idleSubtitle: String {
        guard let device = devices.selected else {
            return "Aucun micro n'est disponible."
        }
        return "Le son sera pris avec le micro \(device.name)."
    }

    @ViewBuilder
    private var cameraArea: some View {
        if recorder.cameraDenied {
            PermissionNotice(
                icon: "video.slash",
                title: "Studio n'a pas accès à la caméra",
                message: "Autorisez Studio dans Réglages Système › Confidentialité et sécurité › Caméra, puis revenez ici.",
                mediaType: .video
            )
            .frame(maxWidth: 620, maxHeight: 350)
        } else if camera.cameras.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "video.slash")
                    .font(.system(size: 36))
                Text("Aucune caméra détectée")
                    .font(.system(size: 14))
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: 620, maxHeight: 350)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        } else {
            CameraPreview(session: camera.session)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 620, maxHeight: 350)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Aperçu en direct de la caméra")
        }
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(camera.cameras) { device in
                Button {
                    recorder.selectCamera(device.id)
                } label: {
                    if device.id == currentCameraID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Text(camera.cameras.first(where: { $0.id == currentCameraID })?.name ?? "Caméra")
        }
        .fixedSize()
        .disabled(camera.cameras.isEmpty)
        .accessibilityLabel("Caméra utilisée")
    }

    private var currentCameraID: String? {
        if let id = settings.cameraID, camera.cameras.contains(where: { $0.id == id }) {
            return id
        }
        return camera.cameras.first?.id
    }

    // MARK: Recording

    private var recordingContent: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                PulsingDot(active: recorder.phase == .recording)
                Text(recorder.phase == .paused ? "En pause" : "Enregistrement en cours")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(LevelZone.red.text)
            }

            Text(DurationText.clock(recorder.elapsed))
                .font(.system(size: recorder.mode == .video ? 40 : 76, weight: .light))
                .monospacedDigit()
                .accessibilityLabel("Durée : \(DurationText.spoken(recorder.elapsed))")

            if recorder.mode == .video {
                CameraPreview(session: camera.session)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 292)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                WaveformView(waveform: audio.waveform)
                    .frame(width: 600, height: 72)
            }

            HStack(alignment: .top, spacing: 36) {
                VStack(spacing: 8) {
                    Button {
                        recorder.togglePause()
                    } label: {
                        Image(systemName: recorder.phase == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 22))
                            .frame(width: 64, height: 64)
                            .background(Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(recorder.phase == .paused ? "Reprendre" : "Mettre en pause")
                    Text(recorder.phase == .paused ? "Reprendre" : "Pause")
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)

                VStack(spacing: 8) {
                    RecordButton(symbol: .stop, diameter: 104, label: "Terminer l'enregistrement") {
                        recorder.stop()
                    }
                    Text("Terminer")
                        .font(.system(size: 14, weight: .semibold))
                }

                Color.clear.frame(width: 64, height: 1)
            }
            .disabled(recorder.phase == .finishing)
        }
        .padding(.vertical, 12)
    }
}

/// The red dot that blinks while recording.
private struct PulsingDot: View {
    let active: Bool
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.recordRed)
            .frame(width: 12, height: 12)
            .opacity(active && dimmed && !reduceMotion ? 0.25 : 1)
            .animation(
                active ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: dimmed
            )
            .onAppear { dimmed = true }
            .accessibilityHidden(true)
    }
}

/// Shown when macOS refuses the microphone or the camera to the app.
struct PermissionNotice: View {
    let icon: String
    let title: String
    let message: String
    let mediaType: AVMediaType

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Ouvrir les réglages") {
                Permissions.openSettings(for: mediaType)
            }
            .controlSize(.large)
        }
        .padding()
    }
}

/// Bottom bar: which microphone, its level, and where recordings go.
struct StatusBar: View {
    @EnvironmentObject private var devices: AudioDeviceMonitor
    @EnvironmentObject private var audio: AudioEngineController
    @EnvironmentObject private var recorder: RecorderCoordinator
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var nas: NASManager
    @EnvironmentObject private var navigation: Navigation

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusZone.fill)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(devices.selected?.name ?? "Aucun micro")
                    .fontWeight(.semibold)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(statusZone.text)
            }
            LevelMeterView(meter: audio.meter, height: 6)
                .frame(width: 130)
            Button("Régler le micro…") {
                navigation.route = .micSetup(step: devices.status == .ready ? 2 : 0)
            }
            .disabled(recorder.isBusy)

            Spacer()

            Text(recorder.isBusy ? "Sera enregistré sur" : "Enregistrer sur")
                .foregroundColor(.secondary)
            locationMenu
                .disabled(recorder.isBusy)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(Color.primary.opacity(0.03))
    }

    private var statusZone: LevelZone {
        switch devices.status {
        case .ready: return .green
        case .usingBuiltIn, .noExternalMic: return .orange
        case .noInput: return .red
        }
    }

    private var statusText: String {
        switch devices.status {
        case .ready: return "Micro prêt"
        case .usingBuiltIn: return "Micro du Mac utilisé"
        case .noExternalMic: return "Micro externe non branché"
        case .noInput: return "Branchez un micro"
        }
    }

    private var locationTitle: String {
        switch settings.saveLocation {
        case .mac: return "Ce Mac"
        case .nas: return nas.displayName
        case .both: return "Ce Mac et \(nas.displayName)"
        }
    }

    private var locationMenu: some View {
        Menu {
            locationButton(.mac, "Ce Mac")
            locationButton(.nas, nas.displayName)
                .disabled(!nas.isConfigured)
            locationButton(.both, "Les deux")
                .disabled(!nas.isConfigured)
            Divider()
            Button(nas.isConfigured ? "Vérifier la connexion au NAS…" : "Configurer le NAS…") {
                navigation.route = .nasSetup
            }
        } label: {
            Label(locationTitle, systemImage: settings.saveLocation == .mac ? "laptopcomputer" : "externaldrive.connected.to.line.below")
        }
        .fixedSize()
        .accessibilityLabel("Emplacement d'enregistrement : \(locationTitle)")
    }

    private func locationButton(_ location: SaveLocation, _ title: String) -> some View {
        Button {
            settings.saveLocation = location
        } label: {
            if settings.saveLocation == location {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
