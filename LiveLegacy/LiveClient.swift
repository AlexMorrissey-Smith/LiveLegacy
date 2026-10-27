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

extension Notification.Name {
    static let liveVariantsChanged = Notification.Name("liveVariantsChanged")
    static let liveNewCapture = Notification.Name("liveNewCapture")
    static let liveTriggerFollow = Notification.Name("liveTriggerFollow")
    static let liveDisconnected = Notification.Name("liveDisconnected")
}

/// Client for the Capture One "Live for Studio" HTTP protocol (protocol 1.1).
/// Plain HTTP GETs with query parameters; a long-poll change feed pushes updates.
final class LiveClient {
    let baseURL: URL
    let serverName: String
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

    init(host: String, port: Int, name: String) {
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

    private var sessionParams: [(String, String)] {
        var p = [("sessionID", sessionID)]
        if let c = collectionID { p.append(("collectionID", c)) }
        return p
    }

    /// Handshake, then load the first collection and start the change feed.
    func connect(completion: @escaping (Error?) -> Void) {
        let done: (Error?) -> Void = { e in DispatchQueue.main.async { completion(e) } }
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
        _ = get("getServerStateForLive", sessionParams) { [weak self] data, error in
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
        pollTask = get("getServerChangesForLive", sessionParams, on: pollSession) { [weak self] data, error in
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
        if let objects = json["objects"] as? [[String: Any]] {
            for obj in objects where obj["kObjectKey_ObjectType"] as? String == "kObjectType_CPServer" {
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
            let date = LiveClient.dateFormatter.date(from: dateString)
                ?? existing.map { variants[$0].date } ?? Date()
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
        return get("getImageForLive", params) { [weak self] data, _ in
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
        _ = get("setPropertyForLive", params) { _, _ in }
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
