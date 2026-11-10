import AppKit
import StudioCore
import SwiftUI

/// Connects the NAS the first time, and guides the user through getting it back when it is offline.
struct NASSetupView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var nas: NASManager
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var navigation: Navigation

    @State private var address = ""
    @State private var isMounting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !nas.isConfigured {
                    firstConnection
                } else if nas.isAvailable && !nas.isChecking {
                    connected
                } else {
                    reconnection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .onAppear {
            if nas.isConfigured {
                nas.reconnect()
            }
        }
    }

    private func close() {
        navigation.route = .main
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if library.pendingCount > 0 {
                Label(pendingText, systemImage: "laptopcomputer")
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !nas.isConfigured {
                Button("Annuler", action: close)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            } else if nas.isAvailable && !nas.isChecking {
                Button("Choisir un autre dossier…", action: chooseFolder)
                    .controlSize(.large)
                Button("Terminé", action: close)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Garder sur ce Mac pour l'instant", action: close)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Réessayer") { nas.reconnect() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nas.isChecking)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .background(Color.primary.opacity(0.03))
    }

    private var pendingText: String {
        let count = library.pendingCount
        return count == 1
            ? "1 enregistrement en attente de copie"
            : "\(count) enregistrements en attente de copie"
    }

    // MARK: First connection

    private var firstConnection: some View {
        VStack(spacing: 22) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Connecter le NAS")
                    .font(.system(size: 28, weight: .bold))
                Text("Les enregistrements rangés sur le NAS ne prennent pas de place sur le Mac. Indiquez l'adresse du NAS, puis choisissez le dossier où les ranger.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Adresse du NAS")
                    .fontWeight(.semibold)
                HStack {
                    TextField("smb://nas/enregistrements", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                    Button("Se connecter", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isMounting)
                    if isMounting {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Tailscale doit être connecté. Si le NAS est déjà ouvert dans le Finder, vous pouvez directement choisir le dossier.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Button("Choisir le dossier…", action: chooseFolder)
                    .padding(.top, 4)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(LevelZone.red.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 520, alignment: .leading)
        }
        .padding(.horizontal, 80)
    }

    private func connect() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            text = "smb://" + text
        }
        guard let url = URL(string: text), url.host != nil else {
            errorMessage = "Cette adresse n'est pas valide. Exemple : smb://nas/enregistrements"
            return
        }
        errorMessage = nil
        isMounting = true
        NetworkMount.mount(url) { success in
            isMounting = false
            if success {
                chooseFolder()
            } else {
                errorMessage = "Impossible de joindre le NAS. Vérifiez que Tailscale est connecté, puis l'adresse, l'identifiant et le mot de passe."
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Dossier des enregistrements sur le NAS"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if nas.configure(folder: folder) {
            errorMessage = nil
            // The NAS becomes the favourite location, as soon as it is connected.
            settings.saveLocation = .nas
        } else {
            errorMessage = "Ce dossier se trouve sur le Mac, pas sur le NAS. Choisissez un dossier du NAS (dans « Emplacements » à gauche)."
        }
    }

    // MARK: Connected

    private var connected: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(LevelZone.green.fill)
                .accessibilityHidden(true)
            Text("Le NAS est connecté")
                .font(.system(size: 28, weight: .bold))
            Text("Dossier : \(settings.nasFolderPath ?? "")")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(LevelZone.red.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            Text(settings.saveLocation == .mac
                 ? "Les enregistrements vont pour l'instant sur ce Mac."
                 : "Les nouveaux enregistrements y seront rangés automatiquement.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            if settings.saveLocation == .mac {
                Button("Utiliser le NAS comme emplacement favori") {
                    settings.saveLocation = .nas
                }
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 80)
    }

    // MARK: Reconnection checklist

    private var reconnection: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Text(nas.isChecking ? "Recherche du NAS…" : "Le NAS n'est pas joignable")
                    .font(.system(size: 28, weight: .bold))
                Text("Rien n'est perdu : vos enregistrements sont gardés sur ce Mac et seront copiés sur le NAS dès qu'il sera de nouveau connecté.")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
            }

            VStack(spacing: 0) {
                ForEach(Array(nas.checks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { Divider() }
                    checkRow(check, number: index + 1)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(width: 600)
        }
        .padding(.horizontal, 80)
    }

    private func title(for check: NASCheck) -> String {
        switch (check.kind, check.state) {
        case (.tailscaleInstalled, _): return "Tailscale est installé"
        case (.tailscaleConnected, .failed): return "Tailscale est déconnecté"
        case (.tailscaleConnected, _): return "Tailscale est connecté"
        case (.nasMounted, _): return "Retrouver « \(nas.displayName) »"
        case (.folderFound, _): return "Retrouver le dossier des enregistrements"
        }
    }

    private func checkRow(_ check: NASCheck, number: Int) -> some View {
        HStack(spacing: 14) {
            checkIcon(check.state, number: number)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: check))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(check.state == .pending ? .secondary : .primary)
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.system(size: 12))
                        .foregroundColor(check.state == .ok ? LevelZone.green.text : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if check.state == .failed {
                switch check.kind {
                case .tailscaleInstalled, .tailscaleConnected:
                    Button("Ouvrir Tailscale") { Tailscale.open() }
                        .buttonStyle(.borderedProminent)
                        .disabled(Tailscale.appURL == nil)
                case .nasMounted, .folderFound:
                    Button("Choisir le dossier…", action: chooseFolder)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .background(check.state == .failed ? LevelZone.orange.fill.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func checkIcon(_ state: NASCheck.State, number: Int) -> some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(LevelZone.green.fill)
                .accessibilityLabel("Réussi")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(LevelZone.orange.fill)
                .accessibilityLabel("À corriger")
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        case .pending:
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 2))
                .accessibilityHidden(true)
        }
    }
}
