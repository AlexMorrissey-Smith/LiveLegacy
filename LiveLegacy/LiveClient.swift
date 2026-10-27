import UIKit

/// One image (variant) shared by Capture One.
struct Variant {
    let id: String
    let name: String
    /// Per-share running number from the variant ID prefix ("3/UUID"); grows with each new image.
    var index: Int { Int(id.split(separator: "/").first ?? "") ?? 0 }
    var date: Date
    var width: Double
    var height: Double
    var rating: Int
    var colorTag: Int
}

struct LiveCollection {
    let id: String
    let name: String
    /// Folder path within the session, e.g. "Capture/-Test"; nesting depth is its number of slashes.
    var path: String = ""
    var depth: Int { path.filter { $0 == "/" }.count }
}

/// One setting on a camera tethered to a Capture Pilot server, e.g. aperture or ISO.
struct CameraSetting {
    let id: String
    var name: String
    var value: String
    var values: [String]
    var writable: Bool
    var canIncrement: Bool
    var canDecrement: Bool
}

/// The camera tethered to a Capture Pilot server. Live for Studio never reports one.
struct Camera {
    let id: String
    var name: String
    var settings: [CameraSetting]
    var canRelease: Bool
}

extension Notification.Name {
    static let liveCameraChanged = Notification.Name("liveCameraChanged")
    static let liveVariantsChanged = Notification.Name("liveVariantsChanged")
    static let liveNewCapture = Notification.Name("liveNewCapture")
    static let liveTriggerFollow = Notification.Name("liveTriggerFollow")
    static let liveDisconnected = Notification.Name("liveDisconnected")
}

/// Client for Capture One's two sharing servers, which speak nearly the same HTTP protocol:
/// Live for Studio (protocol 1.1, every call suffixed "ForLive", several collections) and the
/// Capture Pilot mobile server (protocol 2.4, one served folder, plus remote camera control).
/// Plain HTTP GETs with query parameters; a long-poll change feed pushes updates.
final class LiveClient {
    enum Kind: String, Codable {
        case live, pilot
        var label: String { self == .live ? "Live for Studio" : "Capture Pilot" }
    }

    let kind: Kind
    let baseURL: URL
    let serverName: String
    /// Capture Pilot only: the tethered camera, and the server's permission switches.
    private(set) var camera: Camera?
    private(set) var permissions: [String: String] = [:]
    private var revision: Int?
    private(set) var sessionID = ""
    private(set) var collections: [LiveCollection] = []
    private(set) var collectionID: String?
    private(set) var variants: [Variant] = []

    private let session: URLSession
    private let pollSession: URLSession
    private var pollTask: URLSessionDataTask?
    private var pollGeneration = 0
    private var failures = 0
    let imageCache = NSCache<NSString, UIImage>()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'GMT'xxx"
        return f
    }()

    init(host: String, port: Int, name: String, kind: Kind = .live) {
        self.kind = kind
        var comps = URLComponents()
        comps.scheme = "http"
        // Bare IPv6 literals need brackets in a URL.
        comps.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        comps.port = port
        baseURL = comps.url!
        serverName = name

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6

        let pollConfig = URLSessionConfiguration.default
        pollConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The server answers an idle poll after 60 s.
        pollConfig.timeoutIntervalForRequest = 120
        // The built-in demo share answers inside the app instead of over the network.
        if host == DemoServer.host {
            config.protocolClasses = [DemoServer.self]
            pollConfig.protocolClasses = [DemoServer.self]
        }
        session = URLSession(configuration: config)
        pollSession = URLSession(configuration: pollConfig)
        imageCache.totalCostLimit = 150 * 1024 * 1024
    }

    // MARK: Requests

    private func url(_ path: String, _ params: [(String, String)]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps.url!
    }

    private func get(_ path: String, _ params: [(String, String)], on s: URLSession? = nil,
                     completion: @escaping (Data?, Error?) -> Void) -> URLSessionDataTask {
        var req = URLRequest(url: url(path, params))
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = (s ?? session).dataTask(with: req) { data, response, error in
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(nil, NSError(domain: "Live", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
                return
            }
            completion(data, error)
        }
        task.resume()
        return task
    }

    /// Live for Studio names every call with a "ForLive" suffix; Capture Pilot uses the bare name.
    private func ep(_ name: String) -> String { kind == .live ? name + "ForLive" : name }

    private var sessionParams: [(String, String)] {
        var p = [("sessionID", sessionID)]
        if kind == .live, let c = collectionID { p.append(("collectionID", c)) }
        if kind == .pilot, let r = revision { p.append(("revision", "\(r)")) }
        return p
    }

    /// Asks host:port which protocol it speaks, for manually entered servers.
    static func detect(host: String, port: Int, completion: @escaping (Kind?) -> Void) {
        let probe = LiveClient(host: host, port: port, name: host)
        _ = probe.get("getProtocolVersionForLive", [("clientVersion", "1.1")]) { data, _ in
            if data != nil { probe.disconnect(); return DispatchQueue.main.async { completion(.live) } }
            _ = probe.get("getProtocolVersion", []) { data, _ in
                probe.disconnect()
                DispatchQueue.main.async { completion(data != nil ? .pilot : nil) }
            }
        }
    }

    /// Handshake, then load the first collection and start the change feed.
    func connect(completion: @escaping (Error?) -> Void) {
        let done: (Error?) -> Void = { e in DispatchQueue.main.async { completion(e) } }
        if kind == .pilot { return connectPilot(done) }
        _ = get("getProtocolVersionForLive", [("clientVersion", "1.1")]) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error { return done(error) }
            _ = self.get("connectToServiceForLive",
                         [("protocolVersion", "1.1"), ("captureControlsOnly", "0"), ("appVersion", "1.4.2")]) { data, error in
                guard let data = data, let id = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                    return done(error ?? NSError(domain: "Live", code: -1,
                                                 userInfo: [NSLocalizedDescriptionKey: "No session ID"]))
                }
                self.sessionID = id
                // First state call without collection lists the collections.
                self.loadState { error in
                    if let error = error { return done(error) }
                    if let first = self.collections.first {
                        self.selectCollection(first.id) { done($0) }
                    } else {
                        self.startPolling()
                        done(nil)
                    }
                }
            }
        }
    }

    /// Capture Pilot: POST with an empty body, then a single served folder and no collection list.
    private func connectPilot(_ done: @escaping (Error?) -> Void) {
        var req = URLRequest(url: url("connectToService", [("protocolVersion", "2.4")]))
        req.httpMethod = "POST"
        req.httpBody = Data()
        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data, let id = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id != "0" else {
                let message = status == 401 ? "This server needs a password, which isn't supported yet." : "No session ID"
                return done(error ?? NSError(domain: "Live", code: status,
                                             userInfo: [NSLocalizedDescriptionKey: message]))
            }
            self.sessionID = id
            self.collectionID = "pilot"
            self.loadState { error in
                self.startPolling()
                NotificationCenter.default.post(name: .liveVariantsChanged, object: self)
                done(error)
            }
        }.resume()
    }

    func selectCollection(_ id: String, completion: @escaping (Error?) -> Void) {
        collectionID = id
        variants = []
        imageCache.removeAllObjects()
        loadState { [weak self] error in
            self?.startPolling()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .liveVariantsChanged, object: self)
                completion(error)
            }
        }
    }

    private func loadState(completion: @escaping (Error?) -> Void) {
        _ = get(ep("getServerState"), sessionParams) { [weak self] data, error in
            guard let self = self else { return }
            guard let data = data else { return completion(error) }
            DispatchQueue.main.async {
                self.apply(data, isSnapshot: true)
                completion(nil)
            }
        }
    }

    func disconnect() {
        pollGeneration += 1
        pollTask?.cancel()
        session.invalidateAndCancel()
        pollSession.invalidateAndCancel()
    }

    // MARK: Change feed

    private func startPolling() {
        pollGeneration += 1
        pollTask?.cancel()
        failures = 0
        poll(generation: pollGeneration)
    }

    private func poll(generation: Int) {
        guard generation == pollGeneration else { return }
        pollTask = get(ep("getServerChanges"), sessionParams, on: pollSession) { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self = self, generation == self.pollGeneration else { return }
                if let error = error as NSError? {
                    if error.code == NSURLErrorCancelled { return }
                    if error.code == NSURLErrorTimedOut { return self.poll(generation: generation) }
                    self.failures += 1
                    if self.failures >= 5 {
                        NotificationCenter.default.post(name: .liveDisconnected, object: self)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.poll(generation: generation) }
                    return
                }
                self.failures = 0
                // An empty answer means "poll again" (idle timeout or a change is pending).
                if let data = data, !data.isEmpty { self.apply(data, isSnapshot: false) }
                self.poll(generation: generation)
            }
        }
    }

    // MARK: Parsing

    private func apply(_ data: Data, isSnapshot: Bool) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let r = (json["revision"] as? NSNumber)?.intValue { revision = r }
        if let objects = json["objects"] as? [[String: Any]] {
            for obj in objects where obj["kObjectKey_ObjectType"] as? String == "kObjectType_Camera" {
                applyCamera(obj)
            }
            for obj in objects where obj["kObjectKey_ObjectType"] as? String == "kObjectType_CPServer" {
                if kind == .pilot {
                    for p in obj["kObjectKey_Properties"] as? [[String: Any]] ?? [] {
                        guard let id = p["kObjectProperty_PropertyID"] as? String else { continue }
                        permissions[id] = p["kObjectProperty_CurrentValue"] as? String ?? ""
                    }
                    let folder = permissions["kServerProperty_SelectedFolder"] ?? ""
                    collections = [LiveCollection(id: "pilot", name: folder.isEmpty ? serverName : folder, path: "")]
                    NotificationCenter.default.post(name: .liveCameraChanged, object: self)
                }
                if let cols = obj["kObjectKey_Collections"] as? [[String: Any]] {
                    collections = cols.compactMap {
                        guard let id = $0["kObjectCollectionKey_id"] as? String else { return nil }
                        return LiveCollection(id: id, name: $0["kObjectCollectionKey_name"] as? String ?? id,
                                              path: $0["kObjectCollectionKey_relativePath"] as? String ?? "")
                    }
                }
                if !isSnapshot, obj["kObjectKey_TriggerFollow"] as? Bool == true {
                    NotificationCenter.default.post(name: .liveTriggerFollow, object: self)
                }
            }
        }
        // Collection list only, no variants yet.
        guard collectionID != nil, let list = json["variants"] as? [[String: Any]] else { return }
        var newIDs: [String] = []
        for v in list {
            guard let id = v["kVariantKey_VariantID"] as? String else { continue }
            let change = v["kVariantKey_ChangeType"] as? String ?? ""
            if change == "deleted" || change == "removed" {
                variants.removeAll { $0.id == id }
                continue
            }
            let props = v["kVariantKey_Properties"] as? [String: Any] ?? [:]
            let dateString = props["kVariantProperty_Date"] as? String ?? ""
            let existing = variants.firstIndex { $0.id == id }
            // Capture Pilot sends no date, so its running number stands in for capture order.
            let index = Int(id.split(separator: "/").first ?? "") ?? 0
            let date = LiveClient.dateFormatter.date(from: dateString)
                ?? existing.map { variants[$0].date }
                ?? (kind == .pilot ? Date(timeIntervalSince1970: TimeInterval(index)) : Date())
            let variant = Variant(
                id: id,
                name: v["kVariantKey_VariantName"] as? String ?? "",
                date: date,
                width: (props["kVariantProperty_Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (props["kVariantProperty_Height"] as? NSNumber)?.doubleValue ?? 0,
                rating: (props["kVariantProperty_Rating"] as? NSNumber)?.intValue ?? 0,
                colorTag: (props["kVariantProperty_Colortag"] as? NSNumber)?.intValue ?? 0)
            if let i = existing {
                variants[i] = variant
                if change != "metadata" { invalidateImages(for: id) }
            } else {
                variants.append(variant)
                if !isSnapshot { newIDs.append(id) }
            }
        }
        NotificationCenter.default.post(name: .liveVariantsChanged, object: self)
        if let last = newIDs.last {
            NotificationCenter.default.post(name: .liveNewCapture, object: self, userInfo: ["id": last])
        }
    }

    // MARK: Camera (Capture Pilot)

    /// Capture is allowed when the server permits it, a camera is attached and it can release.
    var canCapture: Bool {
        permissions["kServerProperty_Capture_Permission"] == "enabled"
            && permissions["kServerProperty_Capture_Button"] != "disabled" && camera?.canRelease == true
    }

    private func applyCamera(_ obj: [String: Any]) {
        let change = obj["kObjectKey_ChangeType"] as? String ?? ""
        let id = (obj["kObjectKey_ObjectID"] as? String) ?? (obj["kObjectKey_ObjectID"] as? NSNumber)?.stringValue ?? ""
        if change == "deleted" || change == "removed" {
            if camera?.id == id { camera = nil }
            NotificationCenter.default.post(name: .liveCameraChanged, object: self)
            return
        }
        var cam = camera?.id == id ? camera! : Camera(id: id, name: "", settings: [], canRelease: false)
        if let name = obj["kObjectKey_ObjectName"] as? String { cam.name = name }
        // A change carries only the properties that changed, so merge into what we have.
        for p in obj["kObjectKey_Properties"] as? [[String: Any]] ?? [] {
            guard let pid = p["kObjectProperty_PropertyID"] as? String else { continue }
            let value = p["kObjectProperty_CurrentValue"] as? String ?? ""
            if pid == "kCameraCapability_ShutterRelease" { cam.canRelease = value == "enabled"; continue }
            let values = (p["kObjectProperty_Values"] as? String ?? "").components(separatedBy: "#").filter { !$0.isEmpty }
            let setting = CameraSetting(
                id: pid, name: LiveClient.settingName(pid), value: value, values: values,
                writable: (p["kObjectProperty_Permissions"] as? String ?? "").contains("w"),
                canIncrement: p["kObjectProperty_CanIncrement"].map { $0 as? String == "yes" } ?? (values.last != value),
                canDecrement: p["kObjectProperty_CanDecrement"].map { $0 as? String == "yes" } ?? (values.first != value))
            if let i = cam.settings.firstIndex(where: { $0.id == pid }) { cam.settings[i] = setting } else { cam.settings.append(setting) }
        }
        camera = cam
        NotificationCenter.default.post(name: .liveCameraChanged, object: self)
    }

    private static func settingName(_ id: String) -> String {
        let names = ["ExposureISO": "ISO", "Aperture": "Aperture", "ShutterSpeed": "Shutter",
                     "ExposureBias": "Exposure", "ExposureMode": "Mode", "WhiteBalanceMode": "White Balance",
                     "ExposureMeteringMode": "Metering", "DriveMode": "Drive", "ImageCompression": "Format",
                     "MirrorUp": "Mirror Up", "AutoFocusMode": "Focus Mode", "ImageArea": "Image Area"]
        let key = id.replacingOccurrences(of: "kCameraProperty_", with: "")
        return names[key] ?? key
    }

    private func cameraParams(_ setting: String) -> [(String, String)] {
        sessionParams + [("objectType", "kObjectType_Camera"), ("objectID", camera?.id ?? ""), ("propertyID", setting)]
    }

    /// Fires the shutter. The new image arrives through the change feed like any other capture.
    func capture(completion: @escaping (Bool) -> Void = { _ in }) {
        _ = get("capture", sessionParams) { data, _ in
            let ok = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func setCamera(_ setting: String, to value: String) {
        _ = get("setProperty", cameraParams(setting) + [("propertyValue", value)]) { _, _ in }
        guard var cam = camera, let i = cam.settings.firstIndex(where: { $0.id == setting }) else { return }
        cam.settings[i].value = value
        camera = cam
        NotificationCenter.default.post(name: .liveCameraChanged, object: self)
    }

    /// Steps a setting one notch; the server reports the new value through the change feed.
    func stepCamera(_ setting: String, up: Bool) {
        _ = get(up ? "incrementProperty" : "decrementProperty", cameraParams(setting)) { _, _ in }
    }

    /// Luminance histogram of a variant: 256 bars scaled to 0...height.
    func histogram(_ id: String, height: Int = 100, completion: @escaping ([CGFloat]?) -> Void) {
        _ = get("getHistogram", sessionParams + [("id", id), ("width", "256"), ("height", "\(height)")]) { data, _ in
            var bars: [CGFloat]?
            if let d = data, d.count >= 512 {
                bars = (0..<256).map { i in CGFloat(UInt16(d[d.startIndex + 2 * i]) << 8 | UInt16(d[d.startIndex + 2 * i + 1])) / CGFloat(height) }
            }
            DispatchQueue.main.async { completion(bars) }
        }
    }

    // MARK: Images

    private var imageKeys: [String: Set<NSString>] = [:]

    private func invalidateImages(for id: String) {
        imageKeys[id]?.forEach { imageCache.removeObject(forKey: $0) }
        imageKeys[id] = nil
    }

    /// Fetches a JPEG of the variant scaled to fit width x height.
    /// A non-zero rect is a crop in image pixels (left, top, right, bottom).
    @discardableResult
    func image(_ id: String, width: Int, height: Int, rect: CGRect = .zero,
               completion: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        let key = "\(id)|\(width)x\(height)|\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.maxX)),\(Int(rect.maxY))" as NSString
        if let cached = imageCache.object(forKey: key) {
            completion(cached)
            return nil
        }
        var params = sessionParams
        params += [("id", id), ("width", "\(width)"), ("height", "\(height)"),
                   ("left", "\(Int(rect.minX))"), ("top", "\(Int(rect.minY))"),
                   ("right", "\(Int(rect.maxX))"), ("bottom", "\(Int(rect.maxY))")]
        return get(ep("getImage"), params) { [weak self] data, _ in
            let img = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                if let img = img, let self = self {
                    self.imageCache.setObject(img, forKey: key, cost: data?.count ?? 0)
                    self.imageKeys[id, default: []].insert(key)
                }
                completion(img)
            }
        }
    }

    // MARK: Writes

    func setRating(_ rating: Int, for id: String) {
        setProperty("kImageAdjustmentProperty_Rating", rating, for: id)
        update(id) { $0.rating = rating }
    }

    func setColorTag(_ tag: Int, for id: String) {
        setProperty("kImageAdjustmentProperty_ColorTag", tag, for: id)
        update(id) { $0.colorTag = tag }
    }

    private func update(_ id: String, _ change: (inout Variant) -> Void) {
        guard let i = variants.firstIndex(where: { $0.id == id }) else { return }
        change(&variants[i])
        NotificationCenter.default.post(name: .liveVariantsChanged, object: self)
    }

    private func setProperty(_ property: String, _ value: Int, for id: String) {
        var params = sessionParams
        params += [("objectType", "kObjectType_ImageAdjustments"), ("objectID", id),
                   ("propertyID", property), ("propertyValue", "\(value)")]
        _ = get(ep("setProperty"), params) { _, _ in }
    }
}

/// Capture One colour tags, index 0 to 7.
enum ColorTag {
    static let colors: [UIColor] = [
        .clear,
        UIColor(red: 0.92, green: 0.26, blue: 0.24, alpha: 1), // red
        UIColor(red: 0.96, green: 0.58, blue: 0.20, alpha: 1), // orange
        UIColor(red: 0.98, green: 0.84, blue: 0.25, alpha: 1), // yellow
        UIColor(red: 0.36, green: 0.78, blue: 0.35, alpha: 1), // green
        UIColor(red: 0.25, green: 0.53, blue: 0.95, alpha: 1), // blue
        UIColor(red: 0.93, green: 0.42, blue: 0.75, alpha: 1), // pink
        UIColor(red: 0.62, green: 0.38, blue: 0.88, alpha: 1), // purple
    ]
    static let names = ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Pink", "Purple"]
}
