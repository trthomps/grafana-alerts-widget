import CoreGraphics
import Foundation

/// Minimal SVG path-data parser: M L H V C S Q T Z, absolute and relative. No arcs.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Tokens(Array(data.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?        // for S/s
        var lastQuadControl: CGPoint?    // for T/t
        var command: UInt8 = 0

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let c) = next { command = c } else { scanner.pushBack() }
            let relative = command >= 97   // lowercase
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var cubicControl: CGPoint?
            var quadControl: CGPoint?

            switch command | 0x20 {   // lowercase
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                // Further pairs after a moveto are implicit linetos.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "s"):
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "t"):
                let c = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
            default:
                return path   // unsupported command
            }
            lastControl = cubicControl
            lastQuadControl = quadControl
        }
        return path
    }

    private enum Token { case command(UInt8), number }

    private struct Tokens {
        let bytes: [UInt8]
        var index = 0
        var previous = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || (9...13).contains(bytes[index]) {
                index += 1
            }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            previous = index
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (65...90).contains(byte) || (97...122).contains(byte), byte != 101, byte != 69 {   // not e/E
                index += 1
                return .command(byte)
            }
            return .number
        }

        mutating func pushBack() { index = previous }

        /// Handles "-0.6-6.1", ".5.5", "1e-3".
        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            var sawDot = false, sawDigit = false
            while index < bytes.count {
                let b = bytes[index]
                if (48...57).contains(b) { sawDigit = true; index += 1 }
                else if b == 46, !sawDot { sawDot = true; index += 1 }
                else { break }
            }
            if sawDigit, index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
                var look = index + 1
                if look < bytes.count, bytes[look] == 45 || bytes[look] == 43 { look += 1 }
                if look < bytes.count, (48...57).contains(bytes[look]) {
                    index = look
                    while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                }
            }
            guard sawDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii),
                  let value = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
