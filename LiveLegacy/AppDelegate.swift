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
        window.rootViewController = UI.scale == 1 ? nav : ScaledContainer(nav)
        window.makeKeyAndVisible()
    }
}

/// Interface scale. iPad minis use the same point size as full-size iPads on a smaller screen, so everything
/// looks about a fifth smaller; there the whole UI is drawn 1.2x. Launch with "-uiScale 1.0" to override.
enum UI {
    static let scale: CGFloat = {
        let forced = UserDefaults.standard.double(forKey: "uiScale")
        if forced > 0 { return CGFloat(forced) }
        return isMini ? 1.2 : 1
    }()

    private static var isMini: Bool {
        var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if model.isEmpty {
            var info = utsname()
            uname(&info)
            model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        }
        let minis: Set = ["iPad2,5", "iPad2,6", "iPad2,7", "iPad4,4", "iPad4,5", "iPad4,6", "iPad4,7", "iPad4,8",
                          "iPad4,9", "iPad5,1", "iPad5,2", "iPad11,1", "iPad11,2", "iPad14,1", "iPad14,2",
                          "iPad16,1", "iPad16,2"]
        return minis.contains(model)
    }
}

/// Hosts the app at a smaller logical size and scales it up to fill the screen.
final class ScaledContainer: UIViewController {
    private let content: UIViewController

    init(_ content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        addChild(content)
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = UI.scale, v = content.view!
        v.transform = .identity
        v.bounds = CGRect(x: 0, y: 0, width: view.bounds.width / s, height: view.bounds.height / s)
        v.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        v.transform = CGAffineTransform(scaleX: s, y: s)
    }

    override var childForStatusBarStyle: UIViewController? { content }
    override var childForStatusBarHidden: UIViewController? { content }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { content.supportedInterfaceOrientations }
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
