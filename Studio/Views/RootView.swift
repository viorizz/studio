import StudioCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var devices: AudioDeviceMonitor
    @EnvironmentObject private var recorder: RecorderCoordinator
    @EnvironmentObject private var navigation: Navigation

    @State private var micAlert: MicStatus?
    @State private var showMicAlert = false
    @State private var lastAlerted: MicStatus?

    var body: some View {
        Group {
            switch navigation.route {
            case .main:
                switch navigation.tab {
                case .record: RecordView()
                case .history: HistoryView()
                }
            case .micSetup(let step):
                MicSetupView(initialStep: step)
            case .nasSetup:
                NASSetupView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .principal) {
                switch navigation.route {
                case .main:
                    Picker("Affichage", selection: $navigation.tab) {
                        Text("Enregistrer").tag(AppTab.record)
                        Text("Historique").tag(AppTab.history)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(recorder.isBusy)
                case .micSetup:
                    Text("Configuration du micro").font(.headline)
                case .nasSetup:
                    Text("Connexion au NAS").font(.headline)
                }
            }
        }
        .sheet(item: finishedBinding) { finished in
            SaveSheet(recording: finished)
                .interactiveDismissDisabled(true)
        }
        .alert(
            micAlertTitle,
            isPresented: $showMicAlert,
            presenting: micAlert,
            actions: micAlertActions,
            message: micAlertMessage
        )
        .onAppear {
            recorder.activate()
            evaluateMicAlert()
        }
        .onChange(of: devices.status) { _ in
            evaluateMicAlert()
        }
        .onChange(of: navigation.route) { _ in
            evaluateMicAlert()
        }
    }

    /// The save sheet only shows on the main screen, so it steps aside for the NAS assistant.
    private var finishedBinding: Binding<FinishedRecording?> {
        Binding(
            get: { navigation.route == .main ? recorder.finished : nil },
            set: { _ in }
        )
    }

    // MARK: Microphone alert

    /// Shows the alert once per situation: no microphone plugged in, or the Mac's microphone in use.
    private func evaluateMicAlert() {
        let status = devices.status
        guard navigation.route == .main, !recorder.isBusy, recorder.finished == nil else { return }
        if status == .ready {
            lastAlerted = nil
            return
        }
        // The Mac's microphone was chosen on purpose in the assistant: nothing to warn about.
        if let uid = devices.selectedUID, settings.preferredMicUID == uid, settings.isConfigured(uid) {
            return
        }
        guard status != lastAlerted else { return }
        lastAlerted = status
        micAlert = status
        showMicAlert = true
    }

    private var micAlertTitle: String {
        if case .some(.usingBuiltIn) = micAlert {
            return "Le micro du Mac est utilisé"
        }
        return "Aucun micro détecté"
    }

    @ViewBuilder
    private func micAlertActions(_ status: MicStatus) -> some View {
        switch status {
        case .usingBuiltIn(let externalName):
            Button("Utiliser le \(externalName)") {
                useExternalMicrophone()
            }
            Button("Continuer avec le micro du Mac", role: .cancel) {}
        default:
            Button("Configurer le micro") {
                navigation.route = .micSetup(step: 0)
            }
            Button("Plus tard", role: .cancel) {}
        }
    }

    private func micAlertMessage(_ status: MicStatus) -> Text {
        switch status {
        case .usingBuiltIn(let externalName):
            return Text("Le \(externalName) est branché mais n'est pas sélectionné. Avec le micro du Mac, votre voix sera moins nette.")
        case .noInput:
            return Text("Aucun micro n'est branché sur ce Mac. Laissez-vous guider pour brancher et régler le vôtre.")
        default:
            return Text("Le micro externe n'est pas branché. Laissez-vous guider pour le brancher et le régler, cela prend deux minutes.")
        }
    }

    private func useExternalMicrophone() {
        guard let external = devices.suggestedExternal else { return }
        if settings.isConfigured(external.uid) {
            settings.preferredMicUID = external.uid
            devices.select(external.uid)
        } else {
            // Never set up: go through the choice and the level check.
            navigation.route = .micSetup(step: 1)
        }
    }
}
