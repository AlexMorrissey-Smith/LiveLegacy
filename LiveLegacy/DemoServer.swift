import UIKit

/// A pretend Live for Studio share that runs inside the app, so the app can be tried (and reviewed) without
/// Capture One. It answers the same HTTP requests as the real server through a URLProtocol, draws its
/// images in code, and "captures" a new image every 20 seconds so Follow can be seen working.
final class DemoServer: URLProtocol {
    static let host = "demo.livelegacy.invalid"

    private struct Image {
        let index: Int
        let width: Int
        let height: Int
        var rating: Int
        var tag: Int
        var id: String { "\(index)/DEMO-\(index)" }
        var name: String { String(format: "Demo_%04d.jpg", index) }
    }

    private static let queue = DispatchQueue(label: "DemoServer")
    private static var nextIndex = 1
    private static var images: [String: [Image]] = {
        var all: [String: [Image]] = [:]
        let ratings = [5, 4, 0, 3, 0, 2, 4, 1, 0, 3]
        let tags = [4, 0, 0, 1, 3, 0, 5, 0, 2, 0]
        for (collection, count) in [("capture", 10), ("day2", 4), ("selects", 0)] {
            all[collection] = (0..<count).map { i in
                defer { nextIndex += 1 }
                let portrait = nextIndex % 4 == 0
                return Image(index: nextIndex, width: portrait ? 2000 : 3000, height: portrait ? 3000 : 2000,
                             rating: ratings[i % ratings.count], tag: tags[i % tags.count])
            }
        }
        return all
    }()
    private static let collections: [[String: Any]] = [
        ["kObjectCollectionKey_id": "capture", "kObjectCollectionKey_name": "Capture",
         "kObjectCollectionKey_relativePath": "Capture"],
        ["kObjectCollectionKey_id": "day2", "kObjectCollectionKey_name": "Day 2",
         "kObjectCollectionKey_relativePath": "Capture/Day 2"],
        ["kObjectCollectionKey_id": "selects", "kObjectCollectionKey_name": "Selects",
         "kObjectCollectionKey_relativePath": "Selects"],
    ]

    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var q: [String: String] = [:]
        comps.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        let collection = q["collectionID"]
        switch url.lastPathComponent {
        case "getProtocolVersionForLive":
            respond(Data("1.1".utf8))
        case "connectToServiceForLive":
            respond(Data("demo-session".utf8))
        case "getServerStateForLive":
            let list = DemoServer.queue.sync { collection.flatMap { DemoServer.images[$0] } ?? [] }
            respondJSON(state(list))
        case "getServerChangesForLive":
            // Hold the poll like the real server, then deliver a new capture into Capture.
            DemoServer.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self = self, !self.stopped else { return }
                var added: [Image] = []
                if collection == "capture", (DemoServer.images["capture"]?.count ?? 0) < 40 {
                    let img = Image(index: DemoServer.nextIndex, width: 3000, height: 2000, rating: 0, tag: 0)
                    DemoServer.nextIndex += 1
                    DemoServer.images["capture"]?.append(img)
                    added = [img]
                }
                if added.isEmpty { self.respond(Data()) } else { self.respondJSON(["variants": added.map(self.variant)]) }
            }
        case "setPropertyForLive":
            DemoServer.queue.sync {
                guard let id = q["objectID"], let value = Int(q["propertyValue"] ?? "") else { return }
                for key in DemoServer.images.keys {
                    guard let i = DemoServer.images[key]?.firstIndex(where: { $0.id == id }) else { continue }
                    if q["propertyID"] == "kImageAdjustmentProperty_Rating" { DemoServer.images[key]?[i].rating = value }
                    if q["propertyID"] == "kImageAdjustmentProperty_ColorTag" { DemoServer.images[key]?[i].tag = value }
                }
            }
            respond(Data())
        case "getImageForLive":
            let all = DemoServer.queue.sync { DemoServer.images.values.flatMap { $0 } }
            guard let img = all.first(where: { $0.id == q["id"] }) else { return respond(Data(), status: 404) }
            let crop = CGRect(x: Int(q["left"] ?? "") ?? 0, y: Int(q["top"] ?? "") ?? 0,
                              width: (Int(q["right"] ?? "") ?? 0) - (Int(q["left"] ?? "") ?? 0),
                              height: (Int(q["bottom"] ?? "") ?? 0) - (Int(q["top"] ?? "") ?? 0))
            let data = DemoServer.render(img, crop: crop, maxWidth: Int(q["width"] ?? "") ?? 600,
                                         maxHeight: Int(q["height"] ?? "") ?? 400)
            respond(data, type: "image/jpeg")
        default:
            respond(Data(), status: 404)
        }
    }

    override func stopLoading() {
        DemoServer.queue.async { self.stopped = true }
    }

    private func state(_ list: [Image]) -> [String: Any] {
        ["objects": [["kObjectKey_ObjectType": "kObjectType_CPServer", "kObjectKey_Collections": DemoServer.collections]],
         "variants": list.map(variant)]
    }

    private func variant(_ img: Image) -> [String: Any] {
        ["kVariantKey_VariantID": img.id, "kVariantKey_VariantName": img.name,
         "kVariantKey_Properties": ["kVariantProperty_Width": img.width, "kVariantProperty_Height": img.height,
                                    "kVariantProperty_Rating": img.rating, "kVariantProperty_Colortag": img.tag]]
    }

    private func respondJSON(_ object: [String: Any]) {
        respond((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), type: "application/json")
    }

    private func respond(_ data: Data, status: Int = 200, type: String = "text/plain") {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": type]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: Drawing

    /// Draws a simple landscape (sky, sun, layered hills) unique to each image, cropped and scaled like the
    /// real server: an empty crop means the whole image, and the result fits inside maxWidth x maxHeight.
    private static func render(_ img: Image, crop: CGRect, maxWidth: Int, maxHeight: Int) -> Data {
        let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let src = crop.width > 0 && crop.height > 0 ? crop.intersection(full) : full
        let fit = min(CGFloat(max(maxWidth, 16)) / src.width, CGFloat(max(maxHeight, 16)) / src.height)
        let size = CGSize(width: max(1, floor(src.width * fit)), height: max(1, floor(src.height * fit)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            c.scaleBy(x: fit, y: fit)
            c.translateBy(x: -src.minX, y: -src.minY)
            drawScene(c, size: full.size, seed: img.index)
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }

    private static func drawScene(_ c: CGContext, size: CGSize, seed: Int) {
        let hue = CGFloat((seed * 37) % 100) / 100
        let space = CGColorSpaceCreateDeviceRGB()
        let sky = [UIColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1).cgColor,
                   UIColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 0.95, alpha: 1).cgColor]
        if let g = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 1]) {
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height * 0.7), options: [.drawsAfterEndLocation])
        }
        let sunX = size.width * (0.2 + CGFloat((seed * 13) % 60) / 100)
        c.setFillColor(UIColor(hue: 0.12, saturation: 0.35, brightness: 1, alpha: 0.95).cgColor)
        c.fillEllipse(in: CGRect(x: sunX - size.width * 0.06, y: size.height * 0.22, width: size.width * 0.12, height: size.width * 0.12))
        for layer in 0..<3 {
            let base = size.height * (0.55 + CGFloat(layer) * 0.13)
            let amp = size.height * (0.08 - CGFloat(layer) * 0.015)
            let freq = 1.5 + Double((seed + layer * 7) % 5) * 0.6
            let phase = Double(seed * 11 + layer * 29)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: 0, through: Double(size.width), by: Double(size.width) / 60) {
                let y = Double(base) - Double(amp) * sin(x / Double(size.width) * .pi * freq + phase)
                p.addLine(to: CGPoint(x: x, y: y))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.close()
            c.setFillColor(UIColor(hue: (hue + 0.35).truncatingRemainder(dividingBy: 1), saturation: 0.4,
                                   brightness: 0.45 - CGFloat(layer) * 0.12, alpha: 1).cgColor)
            c.addPath(p.cgPath)
            c.fillPath()
        }
    }
}
