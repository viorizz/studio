import SwiftUI

@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Studio", id: "main") {
            RootView()
                .environmentObject(model.settings)
                .environmentObject(model.devices)
                .environmentObject(model.audio)
                .environmentObject(model.camera)
                .environmentObject(model.nas)
                .environmentObject(model.library)
                .environmentObject(model.recorder)
                .environmentObject(model.playback)
                .environmentObject(model.navigation)
        }
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified)
    }
}
