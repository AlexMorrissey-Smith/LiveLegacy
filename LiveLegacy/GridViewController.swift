import UIKit

/// Collection sidebar plus thumbnail grid, with client-side filter and sort.
final class GridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
    UITableViewDataSource, UITableViewDelegate {
    let client: LiveClient
    var follow = false { didSet { followButton.following = follow } }

    private let sidebar = UIView()
    private let sidebarButton = TopBar.iconButton(Icon.sidebar(), size: 24)
    private let collectionsTable = UITableView(frame: .zero, style: .plain)
    private let divider = UIView()
    private let bar = TopBar()
    private let backButton = TopBar.textButton("Shared Projects", chevron: true)
    private let filterButton = TopBar.iconButton(Icon.filter(), size: 32)
    private let sortButton = TopBar.iconButton(Icon.sort(ascending: false), size: 32)
    private let followButton = FollowButton()
    private var collectionView: UICollectionView!
    private var sidebarVisible = true

    private(set) var shown: [Variant] = []
    private var newestFirst = true
    private var ratingFilter = Set<Int>()   // empty = any
    private var tagFilter = Set<Int>()      // empty = any
    private weak var viewer: ViewerViewController?

    static let sidebarWidth: CGFloat = 235

    init(client: LiveClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { client.disconnect() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background

        sidebar.backgroundColor = Theme.sidebar
        sidebarButton.addTarget(self, action: #selector(toggleCollections), for: .touchUpInside)
        sidebar.addSubview(sidebarButton)
        collectionsTable.backgroundColor = .clear
        collectionsTable.separatorStyle = .none
        collectionsTable.dataSource = self
        collectionsTable.delegate = self
        collectionsTable.register(CollectionCell.self, forCellReuseIdentifier: "c")
        sidebar.addSubview(collectionsTable)
        view.addSubview(sidebar)
        divider.backgroundColor = Theme.hairline
        view.addSubview(divider)

        let layout = LeftAlignedFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 28, left: 0, bottom: 20, right: 0)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.background
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.register(ThumbCell.self, forCellWithReuseIdentifier: "t")
        view.addSubview(collectionView)

        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        filterButton.addTarget(self, action: #selector(showFilter), for: .touchUpInside)
        sortButton.addTarget(self, action: #selector(showSort), for: .touchUpInside)
        followButton.pill = false
        followButton.addTarget(self, action: #selector(toggleFollow), for: .touchUpInside)
        bar.leftViews = [backButton]
        bar.titleCenter = 0.42
        bar.middleViews = [(filterButton, 0.6), (sortButton, 0.83)]
        bar.rightViews = [followButton]
        view.addSubview(bar)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(variantsChanged), name: .liveVariantsChanged, object: client)
        nc.addObserver(self, selector: #selector(newCapture(_:)), name: .liveNewCapture, object: client)
        nc.addObserver(self, selector: #selector(triggerFollow), name: .liveTriggerFollow, object: client)
        nc.addObserver(self, selector: #selector(disconnected), name: .liveDisconnected, object: client)
        variantsChanged()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        let w = view.bounds.width, h = view.bounds.height
        let sw = sidebarVisible ? GridViewController.sidebarWidth : 0
        sidebar.frame = CGRect(x: 0, y: 0, width: GridViewController.sidebarWidth, height: h)
        sidebar.isHidden = !sidebarVisible
        divider.frame = CGRect(x: sw, y: 0, width: 1 / UIScreen.main.scale, height: h)
        divider.isHidden = !sidebarVisible
        sidebarButton.frame = CGRect(x: 4, y: top + 10, width: 36, height: 32)
        collectionsTable.frame = CGRect(x: 0, y: top + TopBar.height, width: GridViewController.sidebarWidth,
                                        height: h - top - TopBar.height)
        // When the sidebar is hidden, its toggle moves into the top bar.
        let barX = sw
        bar.frame = CGRect(x: barX, y: 0, width: w - barX, height: top + TopBar.height)
        if !sidebarVisible && sidebarButton.superview !== bar {
            bar.leftViews = [sidebarButton, backButton]
        } else if sidebarVisible && sidebarButton.superview !== sidebar {
            bar.leftViews = [backButton]
            sidebar.addSubview(sidebarButton)
        }
        collectionView.frame = CGRect(x: barX, y: bar.frame.maxY, width: w - barX, height: h - bar.frame.maxY)
        viewer?.view.frame = contentFrame
    }

    @objc private func toggleCollections() {
        sidebarVisible.toggle()
        UIView.animate(withDuration: 0.25) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    @objc private func goBack() { navigationController?.popViewController(animated: true) }

    // MARK: Data

    private func sorted(_ list: [Variant]) -> [Variant] {
        list.sorted { newestFirst ? $0.index > $1.index : $0.index < $1.index }
    }

    private func recompute() {
        shown = sorted(client.variants.filter { v in
            (ratingFilter.isEmpty || ratingFilter.contains(v.rating)) &&
            (tagFilter.isEmpty || tagFilter.contains(v.colorTag))
        })
    }

    @objc private func variantsChanged() {
        recompute()
        collectionView.reloadData()
        collectionsTable.reloadData()
        let col = client.collections.first { $0.id == client.collectionID }
        bar.titleLabel.text = "\(col?.name ?? client.serverName) (\(shown.count))"
        sortButton.setImage(Icon.sort(ascending: !newestFirst), for: .normal)
        filterButton.tintColor = ratingFilter.isEmpty && tagFilter.isEmpty ? .white : Theme.accent
        viewer?.listChanged(shown)
    }

    @objc private func newCapture(_ note: Notification) {
        guard follow, let id = note.userInfo?["id"] as? String else { return }
        openViewer(id: id)
    }

    private var latest: Variant? { client.variants.max { $0.index < $1.index } }

    @objc private func triggerFollow() {
        follow = true
        viewer?.updateFollow()
        if let l = latest { openViewer(id: l.id) }
    }

    @objc private func toggleFollow() {
        follow.toggle()
        if follow, let l = latest { openViewer(id: l.id) }
        viewer?.updateFollow()
    }

    @objc private func disconnected() {
        let a = darkAlert("Project stopped being shared", nil)
        a.addAction(UIAlertAction(title: "Okay", style: .default) { [weak self] _ in
            self?.navigationController?.popToRootViewController(animated: true)
        })
        (navigationController?.topViewController ?? self).present(a, animated: true)
    }

    func openViewer(id: String) {
        let list = shown.contains { $0.id == id } ? shown : sorted(client.variants)
        if let v = viewer {
            v.show(id: id, in: list)
            return
        }
        // Shown inside the content pane so the sidebar stays, like the original.
        let v = ViewerViewController(grid: self, list: list, startID: id)
        v.onBack = { [weak self] in self?.closeViewer() }
        viewer = v
        addChild(v)
        v.view.frame = contentFrame
        v.view.alpha = 0
        view.addSubview(v.view)
        v.didMove(toParent: self)
        UIView.animate(withDuration: 0.2) { v.view.alpha = 1 }
    }

    private func closeViewer() {
        guard let v = viewer else { return }
        viewer = nil
        v.willMove(toParent: nil)
        UIView.animate(withDuration: 0.2, animations: { v.view.alpha = 0 }) { _ in
            v.view.removeFromSuperview()
            v.removeFromParent()
        }
        becomeFirstResponder()
    }

    private var contentFrame: CGRect {
        let sw = sidebarVisible ? GridViewController.sidebarWidth : 0
        return CGRect(x: sw, y: 0, width: view.bounds.width - sw, height: view.bounds.height)
    }

    // MARK: Popovers

    @objc private func showFilter() {
        let content = FilterView(ratings: ratingFilter, tags: tagFilter)
        content.onChange = { [weak self] r, t in
            self?.ratingFilter = r
            self?.tagFilter = t
            self?.variantsChanged()
        }
        PopoverController(content: content, size: FilterView.size).present(from: self, source: filterButton, arrows: .up)
    }

    @objc private func showSort() {
        let b = UIButton(type: .custom)
        b.setTitle("Last Captured", for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16)
        b.contentHorizontalAlignment = .left
        b.titleEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        let arrow = UILabel(frame: CGRect(x: 170, y: 0, width: 30, height: 48))
        arrow.text = newestFirst ? "↓" : "↑"
        arrow.textColor = Theme.accent
        arrow.font = .boldSystemFont(ofSize: 17)
        b.addSubview(arrow)
        b.addTarget(self, action: #selector(sortTapped), for: .touchUpInside)
        PopoverController(content: b, size: CGSize(width: 210, height: 48)).present(from: self, source: sortButton, arrows: .up)
    }

    @objc private func sortTapped() {
        newestFirst.toggle()
        variantsChanged()
        dismiss(animated: true)
    }

    // MARK: Sidebar table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { client.collections.count }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 36 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath) as! CollectionCell
        let c = client.collections[indexPath.row]
        let hasChildren = client.collections.contains { $0.path.hasPrefix(c.path + "/") && !c.path.isEmpty }
        cell.configure(c.name, depth: c.depth, folder: hasChildren, selected: c.id == client.collectionID)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let c = client.collections[indexPath.row]
        guard c.id != client.collectionID else { return }
        // The open image belongs to the old collection.
        closeViewer()
        client.selectCollection(c.id) { _ in }
        tableView.reloadData()
    }

    // MARK: Grid

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "t", for: indexPath) as! ThumbCell
        cell.configure(shown[indexPath.item], number: indexPath.item + 1, client: client)
        return cell
    }

    static let thumbHeight: CGFloat = 133

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let v = shown[indexPath.item]
        let aspect = v.width > 0 && v.height > 0 ? CGFloat(v.width / v.height) : 1.5
        let h = GridViewController.thumbHeight
        return CGSize(width: min(floor(h * aspect), collectionView.bounds.width), height: h)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        follow = false
        openViewer(id: shown[indexPath.item].id)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.collectionView.collectionViewLayout.invalidateLayout() })
    }
}

final class CollectionCell: UITableViewCell {
    private let pill = UIView()
    private let icon = UIImageView(image: Icon.photos())
    private let name = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        pill.layer.cornerRadius = 7
        contentView.addSubview(pill)
        icon.tintColor = .white
        name.font = .systemFont(ofSize: 15)
        [icon, name].forEach(pill.addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var depth = 0

    func configure(_ title: String, depth: Int, folder: Bool, selected: Bool) {
        name.text = title
        self.depth = depth
        icon.image = folder ? Icon.folder() : Icon.photos()
        setNeedsLayout()
        pill.backgroundColor = selected ? Theme.accent : .clear
        name.textColor = .white
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Subfolders step in, as in the original sidebar.
        let indent = CGFloat(depth) * 20
        pill.frame = contentView.bounds.insetBy(dx: 14, dy: 2)
        pill.frame.origin.x += indent
        pill.frame.size.width -= indent
        icon.frame = CGRect(x: 6, y: (pill.bounds.height - 16) / 2, width: 18, height: 16)
        name.frame = CGRect(x: 30, y: 0, width: pill.bounds.width - 36, height: pill.bounds.height)
    }
}

final class ThumbCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let ratingBadge = UILabel()
    private let numberBadge = UILabel()
    private let tagView = UIView()
    private var currentID: String?
    private var task: URLSessionDataTask?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.18, alpha: 1)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        ratingBadge.font = .systemFont(ofSize: 9, weight: .semibold)
        ratingBadge.textColor = UIColor(white: 1, alpha: 0.7)
        ratingBadge.textAlignment = .center
        ratingBadge.backgroundColor = UIColor(white: 0.25, alpha: 0.85)
        ratingBadge.layer.cornerRadius = 9
        ratingBadge.clipsToBounds = true
        numberBadge.font = .systemFont(ofSize: 9, weight: .bold)
        numberBadge.textColor = UIColor(white: 0.18, alpha: 1)
        numberBadge.textAlignment = .center
        numberBadge.backgroundColor = UIColor(white: 0.55, alpha: 0.9)
        numberBadge.layer.cornerRadius = 1.5
        numberBadge.clipsToBounds = true
        tagView.layer.cornerRadius = 2
        [imageView, ratingBadge, numberBadge, tagView].forEach(contentView.addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        imageView.frame = b
        let rw = max(18, ratingBadge.intrinsicContentSize.width + 8)
        ratingBadge.frame = CGRect(x: 5, y: b.height - 23, width: rw, height: 18)
        let nw = max(11, numberBadge.intrinsicContentSize.width + 4)
        numberBadge.frame = CGRect(x: b.width - nw - 5, y: 5, width: nw, height: 11)
        tagView.frame = CGRect(x: b.width - 15, y: b.height - 15, width: 10, height: 10)
    }

    func configure(_ v: Variant, number: Int, client: LiveClient) {
        ratingBadge.text = "\(v.rating)★"
        ratingBadge.isHidden = v.rating == 0
        numberBadge.text = "\(number)"
        let tag = min(max(v.colorTag, 0), 7)
        tagView.isHidden = tag == 0
        tagView.backgroundColor = ColorTag.colors[tag]
        setNeedsLayout()
        guard v.id != currentID || imageView.image == nil else { return }
        currentID = v.id
        imageView.image = nil
        task?.cancel()
        let scale = UIScreen.main.scale
        let h = Int(GridViewController.thumbHeight * scale)
        task = client.image(v.id, width: h * 2, height: h) { [weak self] img in
            guard let self = self, self.currentID == v.id else { return }
            self.imageView.image = img
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        currentID = nil
        imageView.image = nil
    }
}

/// Filter popover: RATING 0–5 and TAG none + seven colours. Selections combine; nothing selected = show all.
final class FilterView: UIView {
    static let size = CGSize(width: 330, height: 150)
    var onChange: ((Set<Int>, Set<Int>) -> Void)?
    private var ratings: Set<Int>
    private var tags: Set<Int>
    private var ratingButtons: [UIButton] = []
    private var tagButtons: [UIButton] = []

    init(ratings: Set<Int>, tags: Set<Int>) {
        self.ratings = ratings
        self.tags = tags
        super.init(frame: CGRect(origin: .zero, size: FilterView.size))
        addHeader("RATING", y: 14)
        addHeader("TAG", y: 82)
        for r in 0...5 {
            let b = UIButton(type: .custom)
            b.tag = r
            b.frame = CGRect(x: 18 + CGFloat(r) * 38, y: 36, width: 28, height: 28)
            b.setTitle("\(r)", for: .normal)
            b.titleLabel?.font = .boldSystemFont(ofSize: 13)
            b.layer.cornerRadius = 5
            b.addTarget(self, action: #selector(ratingTapped(_:)), for: .touchUpInside)
            ratingButtons.append(b)
            addSubview(b)
        }
        for t in 0...7 {
            let b = tagSwatch(t, size: 28)
            b.frame.origin = CGPoint(x: 18 + CGFloat(t) * 38, y: 104)
            b.addTarget(self, action: #selector(tagTapped(_:)), for: .touchUpInside)
            tagButtons.append(b)
            addSubview(b)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addHeader(_ text: String, y: CGFloat) {
        let l = UILabel(frame: CGRect(x: 18, y: y, width: 200, height: 16))
        l.attributedText = NSAttributedString(string: text, attributes: [
            .kern: 1.5, .font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: Theme.secondaryText])
        addSubview(l)
    }

    private func refresh() {
        for b in ratingButtons {
            let on = ratings.contains(b.tag)
            b.backgroundColor = on ? Theme.accent : Theme.control
            b.setTitleColor(on ? .white : UIColor(white: 0.8, alpha: 1), for: .normal)
        }
        for b in tagButtons {
            let on = tags.contains(b.tag)
            b.layer.borderWidth = on ? 2 : 0
            b.layer.borderColor = UIColor.white.cgColor
            b.layer.cornerRadius = 4
        }
    }

    @objc private func ratingTapped(_ b: UIButton) {
        if ratings.contains(b.tag) { ratings.remove(b.tag) } else { ratings.insert(b.tag) }
        refresh()
        onChange?(ratings, tags)
    }

    @objc private func tagTapped(_ b: UIButton) {
        if tags.contains(b.tag) { tags.remove(b.tag) } else { tags.insert(b.tag) }
        refresh()
        onChange?(ratings, tags)
    }
}

/// Flow layout that packs each row from the left instead of spreading items across it.
final class LeftAlignedFlowLayout: UICollectionViewFlowLayout {
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let attrs = super.layoutAttributesForElements(in: rect)?.map({ $0.copy() as! UICollectionViewLayoutAttributes })
        else { return nil }
        var x = sectionInset.left
        var rowY: CGFloat = -1
        for a in attrs where a.representedElementCategory == .cell {
            if abs(a.frame.minY - rowY) > 1 { x = sectionInset.left; rowY = a.frame.minY }
            a.frame.origin.x = x
            x += a.frame.width + minimumInteritemSpacing
        }
        return attrs
    }
}
