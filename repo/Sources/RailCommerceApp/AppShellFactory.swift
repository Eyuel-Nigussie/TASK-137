#if canImport(UIKit)
import UIKit
import RailCommerce

/// Builds the appropriate root shell for the current device/size class:
/// - **iPhone / compact-width**: `UITabBarController` (existing behavior).
/// - **iPad / regular-width**: `UISplitViewController` (two-column) with the same
///   role-aware tabs collapsed into a primary list. This satisfies the "iPad
///   split-view + rotation" UX requirement without forking every feature VC.
enum AppShellFactory {
    static func makeShell(app: RailCommerce, currentUser: User) -> UIViewController? {
        // Honor the user's horizontal size class on launch — on iPhone we always
        // use a tab bar, on iPad we use a split view that collapses to tab bar on
        // compact size (Slide Over, Split View multitasking).
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .pad {
            return MainSplitViewController(app: app, currentUser: currentUser)
        }
        return MainTabBarController(app: app, currentUser: currentUser)
    }
}
#endif
