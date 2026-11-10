import AppKit
import StudioCore
import SwiftUI

/// Every recording, newest first, with a readable name and where it is stored.
struct HistoryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var playback: PlaybackController
    @EnvironmentObject private var nas: NASManager
    @EnvironmentObject private var navigation: Navigation

    @State private var selection: UUID?
    @State private var query = ""
    @State private var renaming: Recording?
    @State private var newName = ""
    @State private var deleting: Recording?
    @State private var showOfflineAlert = false

    var body: some View {
        VStack(spacing: 0) {
            if library.recordings.isEmpty {
                emptyState
            } else {
                list
            }
            if let recording = selectedRecording {
                Divider()
                playerBar(recording)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Rechercher")
        .alert("Renommer l'enregistrement", isPresented: renamingBinding) {
            TextField("Nom", text: $newName)
            Button("Renommer") {
                if let renaming {
                    library.rename(renaming, to: newName)
                }
                renaming = nil
            }
            Button("Annuler", role: .cancel) {
                renaming = nil
            }
        }
        .confirmationDialog(
            "Supprimer cet enregistrement ?",
            isPresented: deletingBinding,
            presenting: deleting
        ) { recording in
            Button("Supprimer", role: .destructive) {
                delete(recording)
            }
            Button("Annuler", role: .cancel) {}
        } message: { recording in
            Text("« \(recording.name) » sera retiré de l'historique. La copie sur ce Mac ira dans la corbeille ; la copie sur le NAS sera effacée.")
        }
        .background(
            // A second alert needs its own view to attach to.
            Color.clear.alert("Ce fichier est sur le NAS", isPresented: $showOfflineAlert) {
                Button("Reconnecter le NAS") {
                    navigation.route = .nasSetup
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Le NAS n'est pas connecté pour l'instant, le fichier n'est donc pas accessible.")
            }
        )
        .onDisappear {
            playback.stop()
        }
    }

    private var sections: [RecordingSection] {
        LibraryGrouping.sections(for: LibraryGrouping.filter(library.recordings, query: query))
    }

    private var selectedRecording: Recording? {
        library.recordings.first { $0.id == selection }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section(header: Text(section.title)) {
                    ForEach(section.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            isPlaying: playback.isPlaying(recording.id),
                            isBusy: library.busyIDs.contains(recording.id),
                            play: { play(recording) }
                        )
                        .tag(recording.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let recording = library.recordings.first(where: { $0.id == id }) {
                menu(for: recording)
            }
        } primaryAction: { ids in
            if let id = ids.first, let recording = library.recordings.first(where: { $0.id == id }) {
                play(recording)
            }
        }
        .overlay {
            if sections.isEmpty {
                Text("Aucun enregistrement ne correspond à « \(query) ».")
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for recording: Recording) -> some View {
        Button(recording.kind == .video ? "Regarder" : "Écouter") {
            play(recording)
        }
        Button("Renommer…") {
            newName = recording.name
            renaming = recording
        }
        Button("Afficher dans le Finder") {
            reveal(recording)
        }
        if let url = library.accessibleURL(for: recording) {
            ShareLink(item: url) {
                Text("Partager…")
            }
        }
        Divider()
        if recording.onMac, !recording.onNAS, !recording.pendingNASCopy, nas.isConfigured {
            Button("Copier aussi sur le NAS") {
                library.copyToNAS(recording)
            }
        }
        if recording.onNAS, !recording.onMac {
            Button("Copier aussi sur ce Mac") {
                if nas.isAvailable {
                    library.copyToMac(recording)
                } else {
                    showOfflineAlert = true
                }
            }
        }
        Divider()
        Button("Supprimer…", role: .destructive) {
            deleting = recording
        }
    }

    // MARK: Actions

    private func play(_ recording: Recording) {
        guard let url = library.accessibleURL(for: recording) else {
            showOfflineAlert = true
            return
        }
        selection = recording.id
        if recording.kind == .video {
            // Videos open in the default player (QuickTime Player).
            NSWorkspace.shared.open(url)
        } else {
            playback.toggle(id: recording.id, url: url, duration: recording.duration)
        }
    }

    private func reveal(_ recording: Recording) {
        if !library.revealInFinder(recording) {
            showOfflineAlert = true
        }
    }

    private func delete(_ recording: Recording) {
        if playback.currentID == recording.id {
            playback.stop()
        }
        if selection == recording.id {
            selection = nil
        }
        library.delete(recording)
        deleting = nil
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text("Aucun enregistrement pour l'instant")
                .font(.system(size: 20, weight: .semibold))
            Text("Vos enregistrements apparaîtront ici, du plus récent au plus ancien.")
                .foregroundColor(.secondary)
            Button("Faire un enregistrement") {
                navigation.tab = .record
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Player bar

    private func playerBar(_ recording: Recording) -> some View {
        let isCurrent = playback.currentID == recording.id
        let fraction = Binding<Double>(
            get: {
                guard isCurrent, playback.duration > 0 else { return 0 }
                return min(1, max(0, playback.position / playback.duration))
            },
            set: { playback.seek(toFraction: $0) }
        )
        return HStack(spacing: 16) {
            Button {
                play(recording)
            } label: {
                Image(systemName: playIcon(for: recording))
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(recording.kind == .video ? "Regarder" : (playback.isPlaying(recording.id) ? "Mettre en pause" : "Écouter"))

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(recording.fileName)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 250, alignment: .leading)

            if recording.kind == .audio {
                Text(DurationText.short(isCurrent ? playback.position : 0))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Slider(value: fraction)
                    .disabled(!isCurrent)
                    .accessibilityLabel("Position de lecture")
                Text(DurationText.short(recording.duration))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            } else {
                Spacer()
            }

            Button("Afficher dans le Finder") {
                reveal(recording)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
        .background(Color.primary.opacity(0.03))
    }

    private func playIcon(for recording: Recording) -> String {
        if recording.kind == .video { return "play.rectangle.fill" }
        return playback.isPlaying(recording.id) ? "pause.fill" : "play.fill"
    }
}

/// One line of the history.
private struct RecordingRow: View {
    let recording: Recording
    let isPlaying: Bool
    let isBusy: Bool
    let play: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording.kind == .video ? "Regarder « \(recording.name) »" : "Écouter « \(recording.name) »")

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Copie en cours")
            }
            if recording.onMac {
                StorageBadge(kind: .mac)
            }
            if recording.onNAS {
                StorageBadge(kind: .nas)
            } else if recording.pendingNASCopy {
                StorageBadge(kind: .nasPending)
            }
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        if recording.kind == .video { return "video.fill" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private var subtitle: String {
        let date = LibraryGrouping.dateLabel(for: recording.date)
        return "\(date) · \(DurationText.spoken(recording.duration)) · \(recording.kind.label)"
    }
}
