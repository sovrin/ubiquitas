import SwiftUI

@main
struct UbiquitasApp: App {
    @StateObject private var hub = Hub()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(hub: hub)
        } label: {
            // the icon shows when this Mac's keyboard and mouse are on another screen
            Image(systemName: hub.isLocal ? "display.2" : "cursorarrow.motionlines")
                .accessibilityLabel(hub.isLocal ? "ubiquitas" : "ubiquitas, input on \(hub.active)")
        }
        .menuBarExtraStyle(.window)
    }
}
