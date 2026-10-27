import UIKit

/// The shutter and camera-settings buttons shown in the top bar while connected to a Capture Pilot
/// server with a tethered camera. Grid and viewer each own one and lay out `views` in their bar.
final class CameraControls: NSObject {
    let shutterButton = TopBar.iconButton(Icon.shutter(), size: 26)
    let settingsButton = TopBar.iconButton(Icon.camera(), size: 28)
    private let client: LiveClient
    private weak var presenter: UIViewController?
    /// Called when the set of visible buttons changes, so the owner can rebuild its bar.
    var onChange: (() -> Void)?
    private var lastViews: [UIView] = []

    init(client: LiveClient, presenter: UIViewController) {
        self.client = client
        self.presenter = presenter
        super.init()
        shutterButton.addTarget(self, action: #selector(capture), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        NotificationCenter.default.addObserver(self, selector: #selector(cameraChanged), name: .liveCameraChanged, object: client)
        lastViews = views
    }

    /// Settings need a camera and the Capture permission; the shutter also needs the camera ready to fire.
    var views: [UIView] {
        guard client.kind == .pilot, client.camera != nil,
              client.permissions["kServerProperty_Capture_Permission"] == "enabled" else { return [] }
        return client.canCapture ? [shutterButton, settingsButton] : [settingsButton]
    }

    @objc private func cameraChanged() {
        let now = views
        guard now != lastViews else { return }
        lastViews = now
        onChange?()
    }

    @objc func capture() {
        guard client.canCapture else { return }
        shutterButton.tintColor = Theme.accent
        client.capture { [weak self] _ in
            UIView.animate(withDuration: 0.3) { self?.shutterButton.tintColor = .white }
        }
    }

    @objc private func showSettings() {
        guard let presenter = presenter else { return }
        let panel = CameraPanel(client: client)
        PopoverController(content: panel, size: panel.preferredSize)
            .present(from: presenter, source: settingsButton, arrows: isPhone ? [.up, .down] : .up)
    }
}

/// Popover listing the camera's settings, each stepped with - / + or picked from its list, with a
/// histogram of the newest image and a capture button.
final class CameraPanel: UIView {
    private let client: LiveClient
    private let title = UILabel()
    private let histogram = HistogramView()
    private let captureButton = UIButton(type: .custom)
    private var rows: [CameraSettingRow] = []
    private var histogramID: String?
    private static let width: CGFloat = 340, rowHeight: CGFloat = 44, histogramHeight: CGFloat = 64

    init(client: LiveClient) {
        self.client = client
        super.init(frame: .zero)
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 15)
        addSubview(title)
        addSubview(histogram)
        captureButton.setTitle("Capture", for: .normal)
        captureButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        captureButton.backgroundColor = Theme.accent
        captureButton.layer.cornerRadius = 8
        captureButton.addTarget(self, action: #selector(capture), for: .touchUpInside)
        addSubview(captureButton)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: .liveCameraChanged, object: client)
        nc.addObserver(self, selector: #selector(loadHistogram), name: .liveVariantsChanged, object: client)
        refresh()
        loadHistogram()
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: CGSize {
        let count = CGFloat(client.camera?.settings.count ?? 0)
        return CGSize(width: CameraPanel.width,
                      height: 44 + CameraPanel.histogramHeight + 12 + count * CameraPanel.rowHeight + 72)
    }

    @objc private func refresh() {
        guard let cam = client.camera else {
            title.text = "No camera attached"
            rows.forEach { $0.removeFromSuperview() }
            rows = []
            captureButton.isEnabled = false
            captureButton.alpha = 0.4
            return
        }
        // The serial number in brackets is noise here.
        title.text = cam.name.components(separatedBy: " (").first
        if rows.map({ $0.settingID }) != cam.settings.map({ $0.id }) {
            rows.forEach { $0.removeFromSuperview() }
            rows = cam.settings.map { s in
                let r = CameraSettingRow(settingID: s.id)
                r.onStep = { [weak self] up in self?.client.stepCamera(s.id, up: up) }
                r.onPick = { [weak self, weak r] in if let r = r { self?.pick(s.id, from: r) } }
                addSubview(r)
                return r
            }
            setNeedsLayout()
        }
        for (r, s) in zip(rows, cam.settings) { r.show(s) }
        captureButton.isEnabled = client.canCapture
        captureButton.alpha = client.canCapture ? 1 : 0.4
    }

    @objc private func loadHistogram() {
        // Newest capture, which is what the photographer wants to judge.
        guard let newest = client.variants.max(by: { $0.date < $1.date }), newest.id != histogramID else { return }
        histogramID = newest.id
        client.histogram(newest.id) { [weak self] bars in self?.histogram.bars = bars ?? [] }
    }

    private func pick(_ id: String, from row: UIView) {
        guard let setting = client.camera?.settings.first(where: { $0.id == id }), setting.writable,
              let vc = sequence(first: self as UIResponder, next: { $0.next }).first(where: { $0 is UIViewController }) as? UIViewController
        else { return }
        let sheet = UIAlertController(title: setting.name, message: nil, preferredStyle: .actionSheet)
        for v in setting.values {
            sheet.addAction(UIAlertAction(title: v == setting.value ? "✓ \(v)" : v, style: .default) { [weak self] _ in
                self?.client.setCamera(id, to: v)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = row
        sheet.popoverPresentationController?.sourceRect = row.bounds
        vc.present(sheet, animated: true)
    }

    @objc private func capture() {
        captureButton.alpha = 0.5
        client.capture { [weak self] _ in
            UIView.animate(withDuration: 0.3) { self?.captureButton.alpha = 1 }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        title.frame = CGRect(x: 16, y: 10, width: w - 32, height: 24)
        histogram.frame = CGRect(x: 16, y: 44, width: w - 32, height: CameraPanel.histogramHeight)
        var y = histogram.frame.maxY + 12
        for r in rows {
            r.frame = CGRect(x: 0, y: y, width: w, height: CameraPanel.rowHeight)
            y += CameraPanel.rowHeight
        }
        captureButton.frame = CGRect(x: 16, y: bounds.height - 60, width: w - 32, height: 44)
    }
}

/// One camera setting: name on the left, then - value + on the right.
final class CameraSettingRow: UIView {
    let settingID: String
    var onStep: ((Bool) -> Void)?
    var onPick: (() -> Void)?
    private let name = UILabel()
    private let value = UIButton(type: .custom)
    private let minus = UIButton(type: .custom)
    private let plus = UIButton(type: .custom)

    init(settingID: String) {
        self.settingID = settingID
        super.init(frame: .zero)
        name.textColor = Theme.secondaryText
        name.font = .systemFont(ofSize: 15)
        addSubview(name)
        value.setTitleColor(.white, for: .normal)
        value.titleLabel?.font = .boldSystemFont(ofSize: 15)
        value.titleLabel?.adjustsFontSizeToFitWidth = true
        value.titleLabel?.minimumScaleFactor = 0.7
        value.backgroundColor = Theme.control
        value.layer.cornerRadius = 6
        value.addTarget(self, action: #selector(picked), for: .touchUpInside)
        addSubview(value)
        for (b, t) in [(minus, "−"), (plus, "+")] {
            b.setTitle(t, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.setTitleColor(UIColor(white: 1, alpha: 0.25), for: .disabled)
            b.titleLabel?.font = .systemFont(ofSize: 22)
            b.addTarget(self, action: #selector(stepped(_:)), for: .touchUpInside)
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: CameraSetting) {
        name.text = s.name
        value.setTitle(s.value, for: .normal)
        value.isEnabled = s.writable && s.values.count > 1
        minus.isEnabled = s.writable && s.canDecrement
        plus.isEnabled = s.writable && s.canIncrement
        minus.isHidden = !s.writable
        plus.isHidden = !s.writable
    }

    @objc private func stepped(_ b: UIButton) { onStep?(b === plus) }
    @objc private func picked() { onPick?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        plus.frame = CGRect(x: w - 16 - 36, y: 4, width: 36, height: h - 8)
        value.frame = CGRect(x: plus.frame.minX - 4 - 130, y: 6, width: 130, height: h - 12)
        minus.frame = CGRect(x: value.frame.minX - 4 - 36, y: 4, width: 36, height: h - 8)
        name.frame = CGRect(x: 16, y: 0, width: minus.frame.minX - 20, height: h)
    }
}

/// Bar histogram, bars as fractions of full height.
final class HistogramView: UIView {
    var bars: [CGFloat] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.35)
        layer.cornerRadius = 4
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard !bars.isEmpty, let c = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width / CGFloat(bars.count), h = bounds.height
        c.setFillColor(UIColor(white: 0.85, alpha: 0.9).cgColor)
        for (i, b) in bars.enumerated() {
            let bh = min(1, max(0, b)) * h
            c.fill(CGRect(x: CGFloat(i) * w, y: h - bh, width: w + 0.5, height: bh))
        }
    }
}
