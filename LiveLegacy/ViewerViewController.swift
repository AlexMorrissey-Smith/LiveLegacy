import UIKit

/// Single-image viewer shown in the grid's content pane: pinch to zoom (sharp crops fetched for the visible
/// area), swipe to page, vertical star column and colour tag on the right, written back to Capture One.
final class ViewerViewController: UIViewController, UIScrollViewDelegate {
    private weak var grid: GridViewController?
    private var client: LiveClient
    private var list: [Variant]
    private(set) var currentID: String

    private let bar = TopBar()
    private let backButton = TopBar.textButton("Back", chevron: true)
    private let followButton = FollowButton()
    private lazy var camera = CameraControls(client: client, presenter: self)
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let detailView = UIImageView()
    private var starButtons: [UIButton] = []
    private let tagButton = UIButton(type: .custom)
    private var imageTask: URLSessionDataTask?
    private var detailTask: URLSessionDataTask?
    var onBack: (() -> Void)?

    static let railWidth: CGFloat = 54

    init(grid: GridViewController, list: [Variant], startID: String) {
        self.grid = grid
        self.client = grid.client
        self.list = list
        self.currentID = startID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var current: Variant? { client.variants.first { $0.id == currentID } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        detailView.contentMode = .scaleToFill
        imageView.addSubview(detailView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        for dir in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = dir
            scrollView.addGestureRecognizer(swipe)
        }

        // Stars stacked top (5) to bottom (1), as in the original.
        for r in (1...5).reversed() {
            let b = UIButton(type: .custom)
            b.tag = r
            b.tintColor = .white
            b.addTarget(self, action: #selector(starTapped(_:)), for: .touchUpInside)
            starButtons.append(b)
            view.addSubview(b)
        }
        tagButton.tintColor = .white
        tagButton.addTarget(self, action: #selector(tagTapped), for: .touchUpInside)
        view.addSubview(tagButton)

        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        followButton.addTarget(self, action: #selector(followTapped), for: .touchUpInside)
        bar.leftViews = [backButton]
        bar.rightViews = camera.views + [followButton]
        camera.onChange = { [weak self] in
            guard let self = self else { return }
            self.bar.rightViews = self.camera.views + [self.followButton]
        }
        view.addSubview(bar)

        NotificationCenter.default.addObserver(self, selector: #selector(refreshControls),
                                               name: .liveVariantsChanged, object: client)
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        let top = view.safeAreaInsets.top
        bar.frame = CGRect(x: 0, y: 0, width: b.width, height: top + TopBar.height)
        let area: CGRect
        if isPhone {
            // iPhone: stars run left to right (1 to 5) along a bottom rail, tag at the end.
            let bottom = view.safeAreaInsets.bottom
            area = CGRect(x: 0, y: bar.frame.maxY, width: b.width,
                          height: b.height - bar.frame.maxY - bottom - ViewerViewController.railWidth)
            let y = area.maxY + (ViewerViewController.railWidth - 40) / 2
            let total: CGFloat = 5 * 44 + 24 + 40
            let x0 = (b.width - total) / 2
            for s in starButtons {
                s.frame = CGRect(x: x0 + CGFloat(s.tag - 1) * 44, y: y, width: 40, height: 40)
            }
            tagButton.frame = CGRect(x: x0 + 5 * 44 + 24 + 3, y: y + 3, width: 34, height: 34)
        } else {
            area = CGRect(x: 0, y: bar.frame.maxY, width: b.width - ViewerViewController.railWidth,
                          height: b.height - bar.frame.maxY)
            let mid = area.midY
            for (i, s) in starButtons.enumerated() {
                s.frame = CGRect(x: b.width - 44, y: mid - 130 + CGFloat(i) * 40, width: 36, height: 36)
            }
            tagButton.frame = CGRect(x: b.width - 43, y: mid + 82, width: 34, height: 34)
        }
        if scrollView.frame != area {
            scrollView.frame = area
            resetZoom()
        }
    }

    // MARK: Content

    func show(id: String, in newList: [Variant]) {
        list = newList
        guard id != currentID else { return }
        currentID = id
        load()
    }

    func listChanged(_ newList: [Variant]) { list = newList }

    func updateFollow() { refreshControls() }

    private func resetZoom() {
        scrollView.zoomScale = 1
        imageView.frame = scrollView.bounds
        scrollView.contentSize = scrollView.bounds.size
        detailView.isHidden = true
    }

    private func load() {
        imageTask?.cancel()
        detailTask?.cancel()
        imageView.image = nil
        resetZoom()
        refreshControls()
        let scale = UIScreen.main.scale
        let w = Int(max(scrollView.bounds.width, 600) * scale), h = Int(max(scrollView.bounds.height, 400) * scale)
        let id = currentID
        // Small first for speed, then screen resolution.
        imageTask = client.image(id, width: 540, height: 360) { [weak self] img in
            guard let self = self, self.currentID == id else { return }
            if self.imageView.image == nil { self.imageView.image = img }
            self.imageTask = self.client.image(id, width: w, height: h) { [weak self] img in
                guard let self = self, self.currentID == id, let img = img else { return }
                self.imageView.image = img
            }
        }
    }

    @objc private func refreshControls() {
        guard let v = current else { return }
        bar.titleLabel.text = v.name
        for b in starButtons {
            b.setImage(Icon.star(filled: b.tag <= v.rating), for: .normal)
        }
        let tag = min(max(v.colorTag, 0), 7)
        if tag == 0 {
            tagButton.setImage(Icon.square(size: 26), for: .normal)
            tagButton.backgroundColor = .clear
        } else {
            tagButton.setImage(nil, for: .normal)
            tagButton.backgroundColor = ColorTag.colors[tag]
            tagButton.layer.cornerRadius = 5
        }
        let following = grid?.follow ?? false
        followButton.following = following
        view.layer.borderWidth = following && UserDefaults.standard.bool(forKey: "followBorder") ? 4 : 0
        view.layer.borderColor = Theme.accent.cgColor
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        detailView.isHidden = true
        detailTask?.cancel()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        fetchDetail()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { fetchDetail() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { fetchDetail() }

    /// When zoomed in, fetch the visible part of the image at screen resolution and lay it over the base image.
    private func fetchDetail() {
        guard scrollView.zoomScale > 1.05, let v = current, v.width > 0, v.height > 0 else {
            detailView.isHidden = true
            return
        }
        // Rect of the image as drawn (aspect fit) inside imageView's unzoomed bounds.
        let bounds = imageView.bounds
        let fit = min(bounds.width / CGFloat(v.width), bounds.height / CGFloat(v.height))
        let drawn = CGRect(x: (bounds.width - CGFloat(v.width) * fit) / 2,
                           y: (bounds.height - CGFloat(v.height) * fit) / 2,
                           width: CGFloat(v.width) * fit, height: CGFloat(v.height) * fit)
        let visible = scrollView.convert(scrollView.bounds, to: imageView).intersection(drawn)
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return }
        // Visible area in source image pixels.
        let src = CGRect(x: (visible.minX - drawn.minX) / fit, y: (visible.minY - drawn.minY) / fit,
                         width: visible.width / fit, height: visible.height / fit).integral
            .intersection(CGRect(x: 0, y: 0, width: v.width, height: v.height))
        let scale = UIScreen.main.scale * scrollView.zoomScale
        let w = Int(visible.width * scale), h = Int(visible.height * scale)
        let id = currentID
        let zoom = scrollView.zoomScale
        detailTask?.cancel()
        detailTask = client.image(id, width: w, height: h, rect: src) { [weak self] img in
            guard let self = self, self.currentID == id, let img = img, self.scrollView.zoomScale == zoom else { return }
            self.detailView.image = img
            self.detailView.frame = visible
            self.detailView.isHidden = false
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 3, height: scrollView.bounds.height / 3)
            scrollView.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }

    // MARK: Navigation and edits

    @objc private func backTapped() { onBack?() }

    @objc private func swiped(_ g: UISwipeGestureRecognizer) {
        guard scrollView.zoomScale <= 1.01 else { return }
        step(g.direction == .left ? 1 : -1)
    }

    private func step(_ delta: Int) {
        guard let i = list.firstIndex(where: { $0.id == currentID }) else {
            if let first = list.first { currentID = first.id; load() }
            return
        }
        let j = i + delta
        guard list.indices.contains(j) else { return }
        // Manual browsing ends Follow, like the original app.
        if grid?.follow == true { grid?.follow = false }
        currentID = list[j].id
        let t = CATransition()
        t.type = .push
        t.subtype = delta > 0 ? .fromRight : .fromLeft
        t.duration = 0.2
        imageView.layer.add(t, forKey: nil)
        load()
    }

    @objc private func starTapped(_ b: UIButton) {
        guard let v = current else { return }
        // Tapping the current rating clears it.
        client.setRating(v.rating == b.tag ? 0 : b.tag, for: v.id)
    }

    @objc private func tagTapped() {
        let content = UIView()
        for t in 0...7 {
            let s = tagSwatch(t, size: 24)
            s.frame.origin = isPhone ? CGPoint(x: 10 + CGFloat(t) * 38, y: 10) : CGPoint(x: 10, y: 10 + CGFloat(t) * 38)
            s.addTarget(self, action: #selector(swatchTapped(_:)), for: .touchUpInside)
            content.addSubview(s)
        }
        if isPhone {
            PopoverController(content: content, size: CGSize(width: 8 * 38 + 6, height: 44))
                .present(from: self, source: tagButton, arrows: .down)
            return
        }
        PopoverController(content: content, size: CGSize(width: 44, height: 8 * 38 + 6))
            .present(from: self, source: tagButton, arrows: .right)
    }

    @objc private func swatchTapped(_ b: UIButton) {
        dismiss(animated: true)
        guard let v = current else { return }
        client.setColorTag(b.tag, for: v.id)
    }

    @objc private func followTapped() {
        guard let grid = grid else { return }
        grid.follow.toggle()
        if grid.follow, let latest = client.variants.max(by: { $0.index < $1.index }) {
            show(id: latest.id, in: list)
        }
        refreshControls()
    }

    // MARK: Keyboard (external keyboards)

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        var cmds = [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyPrev)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyNext)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(backTapped)),
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(followTapped)),
        ]
        for i in 0...5 {
            cmds.append(UIKeyCommand(input: "\(i)", modifierFlags: [], action: #selector(keyRate(_:))))
        }
        // Colour tags on Option + 0..7.
        for i in 0...7 {
            cmds.append(UIKeyCommand(input: "\(i)", modifierFlags: .alternate, action: #selector(keyTag(_:))))
        }
        return cmds
    }

    @objc private func keyPrev() { step(-1) }
    @objc private func keyNext() { step(1) }

    @objc private func keyRate(_ c: UIKeyCommand) {
        guard let v = current, let r = Int(c.input ?? "") else { return }
        client.setRating(r, for: v.id)
    }

    @objc private func keyTag(_ c: UIKeyCommand) {
        guard let v = current, let t = Int(c.input ?? "") else { return }
        client.setColorTag(t, for: v.id)
    }
}
