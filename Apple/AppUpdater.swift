#if os(macOS)
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheck = false

    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    init() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in self?.canCheck = canCheck }
        }
        controller.startUpdater()
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

struct UpdateMenuItem: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.check)
            .disabled(!updater.canCheck)
    }
}
#endif
