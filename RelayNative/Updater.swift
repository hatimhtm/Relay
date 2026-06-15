import SwiftUI
import Sparkle

// In-app automatic updates via Sparkle. On launch the app begins scheduled background
// checks against a signed appcast on GitHub Releases; when a newer build exists the
// user gets Sparkle's native "Update" prompt (download → install → relaunch) without
// ever visiting GitHub. The "Check for Updates…" menu item and the Settings button
// trigger the same flow on demand.

@MainActor
final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// `Relay ▸ Check for Updates…` menu command.
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = UpdaterModel.shared
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
