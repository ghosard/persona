#if DEBUG && (os(iOS) || os(visionOS))
import SwiftUI
import UIKit

/// `-showStillUI YES`: no animations, for UI tests that check where things end up rather than how they move (#6061): a
/// slide, a fold or a sheet lands at once, so a test waits for its condition instead of for the motion. UIKit's
/// (`UIView.setAnimationsEnabled`, which presentations, pushes and the split's columns go through) and SwiftUI's (every
/// transaction through the root, `stillUI()`). Tests that check a motion itself launch without it.
enum StillUI {
    static let on = UserDefaults.standard.bool(forKey: "showStillUI")

    /// At launch, before the first window: UIKit's animations off.
    @MainActor static func startIfAsked() {
        guard on else { return }
        UIView.setAnimationsEnabled(false)
    }
}

extension View {
    /// SwiftUI's animations off under `-showStillUI` (`withAnimation`, `.animation(_:value:)` and transitions alike).
    @ViewBuilder func stillUI() -> some View {
        if StillUI.on {
            transaction { t in
                t.disablesAnimations = true
                t.animation = nil
            }
        } else {
            self
        }
    }
}
#endif
