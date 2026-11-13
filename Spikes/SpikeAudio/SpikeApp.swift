import SwiftUI

/// Minimal multiplatform SwiftUI host for the Phase 0 audio spike.
@main
struct SpikeApp: App {
    @StateObject private var controller = SpikeController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
