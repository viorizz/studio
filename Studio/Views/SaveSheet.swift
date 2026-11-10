import StudioCore
import SwiftUI

/// Shown when a recording ends: listen, name it, choose where it goes.
struct SaveSheet: View {
    let recording: FinishedRecording

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recorder: RecorderCoordinator
    @EnvironmentObject private var nas: NASManager
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var navigation: Navigation

    @State private var name = ""
    @State private var location: SaveLocation = .mac
    @State private var makeDefault = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let note = recording.note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(LevelZone.orange.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nom dans l'historique")
                    .fontWeight(.semibold)
                TextField("Nom de l'enregistrement", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .onSubmit(save)
                Text("Fichier : \(recording.url.lastPathComponent)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Où l'enregistrer ?")
                    .fontWeight(.semibold)
                VStack(spacing: 0) {
                    locationRow(.mac, icon: "laptopcomputer", title: "Sur ce Mac", detail: "Dossier Musique › Studio")
                    Divider()
                    locationRow(
                        .nas,
                        icon: "externaldrive.connected.to.line.below",
                        title: "Sur le NAS",
                        detail: nasDetail(suffix: "ne prend pas de place sur le Mac")
                    )
                    Divider()
                    locationRow(
                        .both,
                        icon: "square.on.square",
                        title: "Les deux",
                        detail: nasDetail(suffix: "une copie sur le Mac et une sur le NAS")
                    )
                }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if !nas.isConfigured {
                    Button("Configurer le NAS…") {
                        playback.stop()
                        navigation.route = .nasSetup
                    }
                    .buttonStyle(.link)
                }

                Toggle("Utiliser cet emplacement par défaut la prochaine fois", isOn: $makeDefault)
                    .padding(.top, 4)
                    .disabled(location == settings.saveLocation)
            }

            HStack {
                Button("Supprimer l'enregistrement", role: .destructive) {
                    confirmDelete = true
                }
                .buttonStyle(.plain)
                .foregroundColor(LevelZone.red.text)
                Spacer()
                Button("Enregistrer", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            name = RecordingNamer.defaultName(date: recording.date, kind: recording.kind)
            location = nas.isConfigured ? settings.saveLocation : .mac
        }
        .confirmationDialog(
            "Supprimer cet enregistrement ?",
            isPresented: $confirmDelete
        ) {
            Button("Supprimer", role: .destructive) {
                playback.stop()
                recorder.discardFinished()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Il ne sera pas conservé.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                playback.toggle(id: recording.id, url: recording.url, duration: recording.duration)
            } label: {
                Image(systemName: playback.isPlaying(recording.id) ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(playback.isPlaying(recording.id) ? "Mettre en pause" : "Écouter l'enregistrement")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Enregistrement terminé")
                        .font(.system(size: 17, weight: .bold))
                    Spacer()
                    Text("\(recording.kind.label) · \(DurationText.spoken(recording.duration))")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityHidden(true)
            }
        }
    }

    private var progress: Double {
        guard playback.currentID == recording.id, playback.duration > 0 else { return 0 }
        return min(1, max(0, playback.position / playback.duration))
    }

    private func nasDetail(suffix: String) -> String {
        guard nas.isConfigured else { return "Le NAS n'est pas encore configuré" }
        let state = nas.isAvailable ? "connecté" : "hors ligne, la copie se fera plus tard"
        return "\(nas.displayName) · \(state) · \(suffix)"
    }

    private func locationRow(_ value: SaveLocation, icon: String, title: String, detail: String) -> some View {
        let isSelected = location == value
        let enabled = value == .mac || nas.isConfigured
        return Button {
            location = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if value == settings.saveLocation {
                    Label("Favori", systemImage: "star.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save() {
        playback.stop()
        let wantsNAS = location != .mac
        recorder.saveFinished(name: name, location: location, makeDefault: makeDefault)
        guard wantsNAS else { return }
        // The file is safe on the Mac. If the NAS is offline, guide the user to reconnect it.
        nas.refreshAvailability { available in
            if !available {
                navigation.route = .nasSetup
            }
        }
    }
}
