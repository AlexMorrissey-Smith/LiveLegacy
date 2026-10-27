import UIKit

/// "Shared Projects": Bonjour-discovered Capture One sessions plus saved manual entries.
final class ServerListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    NetServiceBrowserDelegate, NetServiceDelegate {
    private struct Manual: Codable { let host: String; let port: Int }
    private struct Row { let name: String; let detail: String; let host: String; let port: Int; let manualIndex: Int? }

    private let bar = TopBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var manual: [Manual] = []
    private var connecting = false
    private let networkButton = TopBar.iconButton(Icon.network(), size: 24)
    private let gearButton = TopBar.iconButton(Icon.gear(), size: 24)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        bar.titleLabel.text = "Shared Projects"
        networkButton.addTarget(self, action: #selector(addManual), for: .touchUpInside)
        gearButton.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        bar.rightViews = [networkButton, gearButton]
        view.addSubview(bar)

        tableView.backgroundColor = Theme.background
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ProjectCell.self, forCellReuseIdentifier: "p")
        view.addSubview(tableView)

        if let data = UserDefaults.standard.data(forKey: "manualServers"),
           let saved = try? JSONDecoder().decode([Manual].self, from: data) {
            manual = saved
        }
        browser.delegate = self
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
        // Testing hook: launch with "-autoConnect host:port" to connect straight away.
        if let target = UserDefaults.standard.string(forKey: "autoConnect"),
           let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) {
            let host = String(target[..<colon])
            DispatchQueue.main.async { self.connect(host: host, port: port, name: host) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        bar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + TopBar.height)
        tableView.frame = CGRect(x: 0, y: bar.frame.maxY, width: view.bounds.width, height: view.bounds.height - bar.frame.maxY)
    }

    // MARK: Bonjour

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        // Every web server on the LAN advertises _http._tcp; keep only Capture One by its TXT record.
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        tableView.reloadData()
    }

    func netServiceDidResolveAddress(_ sender: NetService) { tableView.reloadData() }

    private var rows: [Row] {
        let found: [Row] = services.compactMap { s in
            guard let txt = s.txtRecordData(),
                  NetService.dictionary(fromTXTRecord: txt)["platform"]
                    .flatMap({ String(data: $0, encoding: .utf8) })?.hasPrefix("Capture One") == true,
                  let host = s.hostName, s.port > 0 else { return nil }
            return Row(name: s.name, detail: host, host: host, port: s.port, manualIndex: nil)
        }
        let saved = manual.enumerated().map { i, m in
            Row(name: "\(m.host):\(m.port)", detail: "Manual", host: m.host, port: m.port, manualIndex: i)
        }
        return found + saved
    }

    // MARK: Table

    /// The last row is always the built-in demo project, so the app can be tried without Capture One.
    private var demoRow: Int { max(rows.count, 1) }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { demoRow + 1 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let v = UIView()
        let l = UILabel(frame: CGRect(x: 28, y: 12, width: 300, height: 16))
        l.text = "SHARED"
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = Theme.secondaryText
        v.addSubview(l)
        return v
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 32 }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 36 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "p", for: indexPath) as! ProjectCell
        if indexPath.row == demoRow {
            cell.configure(name: "Demo Project", detail: "Try it without Capture One", placeholder: false)
        } else if rows.isEmpty {
            cell.configure(name: "Searching for shared projects…", detail: "", placeholder: true)
        } else {
            let r = rows[indexPath.row]
            cell.configure(name: r.name, detail: r.detail, placeholder: false)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < rows.count && rows[indexPath.row].manualIndex != nil
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard let i = rows[indexPath.row].manualIndex else { return }
        manual.remove(at: i)
        saveManual()
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == demoRow {
            return connect(host: DemoServer.host, port: 80, name: "Demo Project")
        }
        guard indexPath.row < rows.count else { return }
        let r = rows[indexPath.row]
        connect(host: r.host, port: r.port, name: r.manualIndex == nil ? r.name : r.host)
    }

    // MARK: Actions

    private func connect(host: String, port: Int, name: String) {
        guard !connecting else { return }
        connecting = true
        let client = LiveClient(host: host, port: port, name: name)
        client.connect { [weak self] error in
            guard let self = self else { return }
            self.connecting = false
            if let error = error {
                client.disconnect()
                let a = darkAlert("Could not connect", error.localizedDescription)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(a, animated: true)
                return
            }
            self.navigationController?.pushViewController(GridViewController(client: client), animated: true)
        }
    }

    @objc private func addManual() {
        let a = darkAlert("Connect to Server", "Enter the IP address and port shown in Live for Studio > Network Settings.")
        a.addTextField { $0.placeholder = "IP address"; $0.keyboardType = .numbersAndPunctuation }
        a.addTextField { $0.placeholder = "Port"; $0.keyboardType = .numberPad }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self] _ in
            guard let self = self,
                  let host = a.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
                  let port = Int(a.textFields?[1].text ?? ""), port > 0, port < 65536 else { return }
            if !self.manual.contains(where: { $0.host == host && $0.port == port }) {
                self.manual.append(Manual(host: host, port: port))
                self.saveManual()
                self.tableView.reloadData()
            }
            self.connect(host: host, port: port, name: host)
        })
        present(a, animated: true)
    }

    private func saveManual() {
        UserDefaults.standard.set(try? JSONEncoder().encode(manual), forKey: "manualServers")
    }

    @objc private func showSettings() {
        let content = SettingsView()
        PopoverController(content: content, size: CGSize(width: 320, height: 104)).present(from: self, source: gearButton, arrows: .up)
    }
}

final class ProjectCell: UITableViewCell {
    private let card = UIView()
    private let icon = UIImageView(image: Icon.cast())
    private let name = UILabel()
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        card.backgroundColor = Theme.row
        card.layer.cornerRadius = 6
        contentView.addSubview(card)
        icon.tintColor = .white
        name.textColor = .white
        name.font = .systemFont(ofSize: 15)
        detail.textColor = UIColor(white: 0.78, alpha: 1)
        detail.font = .systemFont(ofSize: 14)
        detail.textAlignment = .right
        [icon, name, detail].forEach(card.addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name n: String, detail d: String, placeholder: Bool) {
        name.text = n
        detail.text = d
        name.textColor = placeholder ? Theme.secondaryText : .white
        icon.isHidden = placeholder
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        card.backgroundColor = highlighted ? Theme.control : Theme.row
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = contentView.bounds.insetBy(dx: 16, dy: 2)
        let h = card.bounds.height
        icon.frame = CGRect(x: 12, y: (h - 16) / 2, width: 18, height: 16)
        detail.frame = CGRect(x: card.bounds.width / 2, y: 0, width: card.bounds.width / 2 - 14, height: h)
        name.frame = CGRect(x: 38, y: 0, width: card.bounds.width / 2 - 40, height: h)
    }
}

/// Gear popover: Prevent Sleep and Follow Border switches.
final class SettingsView: UIView {
    init() {
        super.init(frame: .zero)
        addRow("Prevent Sleep", key: "preventSleep", y: 8) { on in UIApplication.shared.isIdleTimerDisabled = on }
        addRow("Follow Border", key: "followBorder", y: 52) { _ in }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var actions: [String: (Bool) -> Void] = [:]

    private func addRow(_ title: String, key: String, y: CGFloat, action: @escaping (Bool) -> Void) {
        let l = UILabel(frame: CGRect(x: 16, y: y, width: 200, height: 44))
        l.text = title
        l.textColor = .white
        addSubview(l)
        let s = UISwitch()
        s.onTintColor = Theme.accent
        s.isOn = UserDefaults.standard.bool(forKey: key)
        s.frame.origin = CGPoint(x: 320 - 16 - s.frame.width, y: y + 6)
        s.accessibilityIdentifier = key
        s.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        actions[key] = action
        addSubview(s)
    }

    @objc private func changed(_ s: UISwitch) {
        guard let key = s.accessibilityIdentifier else { return }
        UserDefaults.standard.set(s.isOn, forKey: key)
        actions[key]?(s.isOn)
    }
}
