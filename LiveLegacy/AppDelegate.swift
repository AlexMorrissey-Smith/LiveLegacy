import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // iOS 13+ uses SceneDelegate; iOS 12 builds the window here.
        if #available(iOS 13, *) {} else {
            window = UIWindow(frame: UIScreen.main.bounds)
            AppDelegate.setUp(window!)
        }
        UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.bool(forKey: "preventSleep")
        return true
    }

    static func setUp(_ window: UIWindow) {
        let nav = UINavigationController(rootViewController: ServerListViewController())
        nav.setNavigationBarHidden(true, animated: false)
        window.rootViewController = nav
        window.makeKeyAndVisible()
    }
}

/// Only used on iOS 13 and later (current iOS refuses apps without a scene lifecycle).
@available(iOS 13, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: windowScene)
        AppDelegate.setUp(window!)
    }
}

enum Theme {
    static let background = UIColor(white: 0.122, alpha: 1)   // content area
    static let sidebar = UIColor(white: 0.102, alpha: 1)
    static let bar = UIColor(white: 0.098, alpha: 1)
    static let hairline = UIColor(white: 0.2, alpha: 1)
    static let row = UIColor(white: 0.17, alpha: 1)
    static let popover = UIColor(white: 0.16, alpha: 1)
    static let control = UIColor(white: 0.3, alpha: 1)
    static let secondaryText = UIColor(white: 0.62, alpha: 1)
    static let accent = UIColor(red: 0.29, green: 0.6, blue: 0.97, alpha: 1)
}
