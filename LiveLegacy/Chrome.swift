import UIKit

/// The flat dark top bar used on every screen (the original app has no system-style navigation bar).
final class TopBar: UIView {
    static let height: CGFloat = 52
    let titleLabel = UILabel()
    /// Horizontal centre of the title as a fraction of the bar width.
    var titleCenter: CGFloat = 0.5 { didSet { setNeedsLayout() } }
    private let line = UIView()
    var leftViews: [UIView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; leftViews.forEach(addSubview); setNeedsLayout() } }
    var rightViews: [UIView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; rightViews.forEach(addSubview); setNeedsLayout() } }
    /// Views centred in the bar between title and right views (filter / sort icons).
    var middleViews: [(UIView, CGFloat)] = [] { didSet { oldValue.forEach { $0.0.removeFromSuperview() }; middleViews.forEach { addSubview($0.0) }; setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)
        line.backgroundColor = Theme.hairline
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = safeAreaInsets.top
        let h = bounds.height - top
        line.frame = CGRect(x: 0, y: bounds.height - 1 / UIScreen.main.scale, width: bounds.width, height: 1 / UIScreen.main.scale)
        // Side insets keep items clear of the notch on landscape iPhones.
        var x: CGFloat = 12 + safeAreaInsets.left
        for v in leftViews {
            let s = v.sizeThatFits(CGSize(width: 400, height: h))
            v.frame = CGRect(x: x, y: top + (h - s.height) / 2, width: s.width, height: s.height)
            x += s.width + 12
        }
        var r = bounds.width - 12 - safeAreaInsets.right
        for v in rightViews.reversed() {
            let s = v.sizeThatFits(CGSize(width: 400, height: h))
            r -= s.width
            v.frame = CGRect(x: r, y: top + (h - s.height) / 2, width: s.width, height: s.height)
            r -= 16
        }
        for (v, fraction) in middleViews {
            let s = v.sizeThatFits(CGSize(width: 400, height: h))
            v.frame = CGRect(x: bounds.width * fraction - s.width / 2, y: top + (h - s.height) / 2, width: s.width, height: s.height)
        }
        let tw = min(titleLabel.intrinsicContentSize.width, bounds.width * 0.4)
        titleLabel.frame = CGRect(x: bounds.width * titleCenter - tw / 2, y: top, width: tw, height: h)
    }

    static func iconButton(_ image: UIImage, size: CGFloat = 32) -> UIButton {
        let b = SizedButton(type: .custom)
        b.fixedSize = CGSize(width: size + 12, height: size + 8)
        b.setImage(image, for: .normal)
        b.tintColor = .white
        return b
    }

    static func textButton(_ title: String, chevron: Bool = false) -> UIButton {
        let b = SizedButton(type: .system)
        b.tintColor = .white
        b.titleLabel?.font = .boldSystemFont(ofSize: 16)
        b.setTitle(title, for: .normal)
        if chevron {
            b.setImage(Icon.chevronLeft(), for: .normal)
            b.titleEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: -10)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        }
        return b
    }
}

class SizedButton: UIButton {
    var fixedSize: CGSize?
    override func sizeThatFits(_ size: CGSize) -> CGSize { fixedSize ?? super.sizeThatFits(size) }
    override var intrinsicContentSize: CGSize { fixedSize ?? super.intrinsicContentSize }
}

/// Follow button: filled blue pill when off ("Follow"), outlined pill when on ("Stop Following").
final class FollowButton: SizedButton {
    var following = false { didSet { update() } }
    var pill = true { didSet { update() } }

    convenience init() {
        self.init(type: .custom)
        titleLabel?.font = .boldSystemFont(ofSize: 15)
        layer.cornerRadius = 15
        contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        update()
    }

    private func update() {
        setTitle(following ? "Stop Following" : "Follow", for: .normal)
        setTitleColor(.white, for: .normal)
        if pill {
            backgroundColor = following ? .clear : Theme.accent
            layer.borderWidth = following ? 1 : 0
            layer.borderColor = UIColor(white: 0.75, alpha: 1).cgColor
        } else {
            // Grid screen: plain text, accent when following.
            backgroundColor = .clear
            layer.borderWidth = 0
            setTitleColor(following ? Theme.accent : .white, for: .normal)
        }
        let s = super.sizeThatFits(CGSize(width: 300, height: 30))
        fixedSize = CGSize(width: s.width, height: 30)
        superview?.setNeedsLayout()
    }
}

/// True on iPhone and iPod touch, which get the compact layout.
var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

/// Bottom toolbar used by the compact (iPhone) layout; items are spread evenly across it.
final class BottomBar: UIView {
    static let height: CGFloat = 49
    private let line = UIView()
    var items: [UIView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; items.forEach(addSubview); setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar
        line.backgroundColor = Theme.hairline
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / UIScreen.main.scale)
        let left = safeAreaInsets.left + 8, w = bounds.width - left - safeAreaInsets.right - 8
        let slot = w / CGFloat(max(items.count, 1))
        for (i, v) in items.enumerated() {
            let s = v.sizeThatFits(CGSize(width: slot, height: BottomBar.height))
            v.frame = CGRect(x: left + slot * (CGFloat(i) + 0.5) - s.width / 2, y: (BottomBar.height - s.height) / 2,
                             width: s.width, height: s.height)
        }
    }
}

/// Dark popover container; iOS 12 popovers are light by default.
final class PopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    let content: UIView
    init(content: UIView, size: CGSize) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
        preferredContentSize = size
        popoverPresentationController?.delegate = self
        popoverPresentationController?.backgroundColor = Theme.popover
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.popover
        view.addSubview(content)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.frame = view.bounds.inset(by: view.safeAreaInsets)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

    func present(from vc: UIViewController, source: UIView, arrows: UIPopoverArrowDirection = .any) {
        popoverPresentationController?.sourceView = source
        popoverPresentationController?.sourceRect = source.bounds
        popoverPresentationController?.permittedArrowDirections = arrows
        vc.present(self, animated: true)
    }
}

/// Colour swatch button for tag pickers.
func tagSwatch(_ tag: Int, size: CGFloat) -> UIButton {
    let b = UIButton(type: .custom)
    b.tag = tag
    b.frame.size = CGSize(width: size, height: size)
    if tag == 0 {
        b.setImage(Icon.square(slashed: true, size: size), for: .normal)
        b.tintColor = UIColor(white: 0.85, alpha: 1)
    } else {
        b.backgroundColor = ColorTag.colors[tag]
        b.layer.cornerRadius = 4
    }
    return b
}

/// Alert styled dark (iOS 12 alerts ignore dark mode).
func darkAlert(_ title: String?, _ message: String?) -> UIAlertController {
    let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
    a.view.tintColor = Theme.accent
    return a
}
