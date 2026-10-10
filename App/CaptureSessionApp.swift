import SwiftUI
import CaptureCore

@main
struct CaptureSessionApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Capture Session") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
        }
        Window("Controller", id: "controller") {
            ControllerView()
                .environmentObject(model)
                .environmentObject(model.store)
        }
        .windowResizability(.contentMinSize)
    }
}
