import AppKit
import Sparkle

// Sparkle asks the app to quit with a regular terminate request. AppKit refuses that request
// while any window has a sheet attached ("App termination blocked by modal sheet"), so the
// "Restart" button in the update dialog did nothing until the user quit the app by hand.
// Dismissing the sheets right before the relaunch lets the request through.
//
// Lifetime: SPUStandardUpdaterController keeps its delegate weakly, hence the shared instance.
final class SparkleRelaunchHandler: NSObject, SPUUpdaterDelegate {

    static let shared = SparkleRelaunchHandler()

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                // Nested sheets: end the topmost first so the parent can close too.
                var sheet = window.attachedSheet
                while let next = sheet?.attachedSheet { sheet = next }
                while let current = sheet {
                    let parent = current.sheetParent
                    parent?.endSheet(current)
                    current.orderOut(nil)
                    sheet = parent?.attachedSheet
                }
            }
        }
    }
}
