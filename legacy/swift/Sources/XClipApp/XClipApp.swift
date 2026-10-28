import SwiftUI

@main
struct XClipApp: App {
    var body: some Scene {
        Window("xclip", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1240, height: 860)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}
