import UIKit

/// Line icons drawn in code, since SF Symbols do not exist on iOS 12.
enum Icon {
    private static var cache: [String: UIImage] = [:]

    private static func draw(_ key: String, _ size: CGSize, _ body: (CGContext) -> Void) -> UIImage {
        if let img = cache[key] { return img }
        let img = UIGraphicsImageRenderer(size: size).image { body($0.cgContext) }
            .withRenderingMode(.alwaysTemplate)
        cache[key] = img
        return img
    }

    private static func stroke(_ path: UIBezierPath, _ width: CGFloat = 1.5) {
        UIColor.black.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    static func star(filled: Bool, size: CGFloat = 26) -> UIImage {
        draw("star\(filled)\(size)", CGSize(width: size, height: size)) { _ in
            let c = CGPoint(x: size / 2, y: size / 2 + size * 0.04)
            let outer = size * 0.46, inner = outer * 0.42
            let path = UIBezierPath()
            for i in 0..<10 {
                let r = i % 2 == 0 ? outer : inner
                let a = CGFloat(i) * .pi / 5 - .pi / 2
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.close()
            if filled { UIColor.black.setFill(); path.fill() } else { stroke(path, 1.4) }
        }
    }

    static func filter() -> UIImage {
        draw("filter", CGSize(width: 32, height: 32)) { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 3, y: 4))
            p.addLine(to: CGPoint(x: 29, y: 4))
            p.addLine(to: CGPoint(x: 19, y: 16))
            p.addLine(to: CGPoint(x: 18, y: 29))
            p.addLine(to: CGPoint(x: 14, y: 25))
            p.addLine(to: CGPoint(x: 13, y: 16))
            p.close()
            stroke(p, 1.6)
        }
    }

    static func sort(ascending: Bool) -> UIImage {
        draw("sort\(ascending)", CGSize(width: 32, height: 32)) { _ in
            let p = UIBezierPath()
            for (i, w) in [28, 22, 15, 9].enumerated() {
                let y = CGFloat(4 + i * 7)
                p.move(to: CGPoint(x: 2, y: y)); p.addLine(to: CGPoint(x: CGFloat(w), y: y))
            }
            p.move(to: CGPoint(x: 24, y: 14)); p.addLine(to: CGPoint(x: 24, y: 30))
            if ascending {
                p.move(to: CGPoint(x: 20, y: 18)); p.addLine(to: CGPoint(x: 24, y: 14)); p.addLine(to: CGPoint(x: 28, y: 18))
            } else {
                p.move(to: CGPoint(x: 20, y: 26)); p.addLine(to: CGPoint(x: 24, y: 30)); p.addLine(to: CGPoint(x: 28, y: 26))
            }
            stroke(p, 1.4)
        }
    }

    static func chevronLeft() -> UIImage {
        draw("chev", CGSize(width: 12, height: 20)) { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 9, y: 3)); p.addLine(to: CGPoint(x: 3, y: 10)); p.addLine(to: CGPoint(x: 9, y: 17))
            stroke(p, 2)
        }
    }

    static func sidebar() -> UIImage {
        draw("sidebar", CGSize(width: 24, height: 20)) { _ in
            let r = UIBezierPath(roundedRect: CGRect(x: 2, y: 3, width: 20, height: 14), cornerRadius: 2.5)
            stroke(r, 1.4)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 8, y: 3)); p.addLine(to: CGPoint(x: 8, y: 17))
            for y in [6.5, 9.5, 12.5] as [CGFloat] { p.move(to: CGPoint(x: 4, y: y)); p.addLine(to: CGPoint(x: 6, y: y)) }
            stroke(p, 1.2)
        }
    }

    static func network() -> UIImage {
        draw("network", CGSize(width: 24, height: 24)) { _ in
            stroke(UIBezierPath(roundedRect: CGRect(x: 4, y: 2, width: 16, height: 13), cornerRadius: 2), 1.5)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 12, y: 15)); p.addLine(to: CGPoint(x: 12, y: 21))
            p.move(to: CGPoint(x: 3, y: 21)); p.addLine(to: CGPoint(x: 21, y: 21))
            stroke(p, 1.5)
        }
    }

    static func gear() -> UIImage {
        draw("gear", CGSize(width: 24, height: 24)) { _ in
            let c = CGPoint(x: 12, y: 12)
            let p = UIBezierPath()
            let teeth = 8
            for i in 0..<(teeth * 4) {
                let a = CGFloat(i) * .pi * 2 / CGFloat(teeth * 4) - .pi / 2
                let r: CGFloat = (i % 4 == 0 || i % 4 == 1) ? 10 : 7.6
                let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.close()
            stroke(p, 1.4)
            stroke(UIBezierPath(arcCenter: c, radius: 3.2, startAngle: 0, endAngle: .pi * 2, clockwise: true), 1.4)
        }
    }

    static func cast() -> UIImage {
        draw("cast", CGSize(width: 18, height: 16)) { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 2, y: 6)); p.addLine(to: CGPoint(x: 2, y: 3)); p.addLine(to: CGPoint(x: 16, y: 3))
            p.addLine(to: CGPoint(x: 16, y: 13)); p.addLine(to: CGPoint(x: 9, y: 13))
            p.move(to: CGPoint(x: 2, y: 9)); p.addQuadCurve(to: CGPoint(x: 6, y: 13), controlPoint: CGPoint(x: 6, y: 9))
            p.move(to: CGPoint(x: 2, y: 12)); p.addLine(to: CGPoint(x: 3, y: 13))
            stroke(p, 1.2)
        }
    }

    static func photos() -> UIImage {
        draw("photos", CGSize(width: 18, height: 16)) { _ in
            stroke(UIBezierPath(roundedRect: CGRect(x: 2, y: 4, width: 13, height: 10), cornerRadius: 1.5), 1.3)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 5, y: 2)); p.addLine(to: CGPoint(x: 16, y: 2)); p.addLine(to: CGPoint(x: 16, y: 11))
            p.move(to: CGPoint(x: 3, y: 13)); p.addLine(to: CGPoint(x: 7, y: 9)); p.addLine(to: CGPoint(x: 10, y: 12))
            p.addLine(to: CGPoint(x: 12, y: 10)); p.addLine(to: CGPoint(x: 14, y: 12))
            stroke(p, 1.2)
        }
    }

    static func folder() -> UIImage {
        draw("folder", CGSize(width: 18, height: 16)) { _ in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 2, y: 13)); p.addLine(to: CGPoint(x: 2, y: 3.5))
            p.addLine(to: CGPoint(x: 6.5, y: 3.5)); p.addLine(to: CGPoint(x: 8, y: 5))
            p.addLine(to: CGPoint(x: 16, y: 5)); p.addLine(to: CGPoint(x: 16, y: 13)); p.close()
            p.move(to: CGPoint(x: 2, y: 7)); p.addLine(to: CGPoint(x: 16, y: 7))
            stroke(p, 1.3)
        }
    }

    static func square(slashed: Bool = false, size: CGFloat = 24) -> UIImage {
        draw("sq\(slashed)\(size)", CGSize(width: size, height: size)) { _ in
            let r = CGRect(x: 2, y: 2, width: size - 4, height: size - 4)
            stroke(UIBezierPath(roundedRect: r, cornerRadius: size * 0.18), 1.6)
            if slashed {
                let p = UIBezierPath()
                p.move(to: CGPoint(x: r.minX + 1, y: r.minY + 1)); p.addLine(to: CGPoint(x: r.maxX - 1, y: r.maxY - 1))
                stroke(p, 1.4)
            }
        }
    }
}
