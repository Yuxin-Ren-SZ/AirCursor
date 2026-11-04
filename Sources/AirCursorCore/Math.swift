import Foundation

/// Minimal 2D vector used by the pointer pipeline (kept free of AppKit/CoreGraphics).
public struct Vec2: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }
}

public enum AngleMath {
    /// Shortest signed difference `a - b` in radians, wrapped into (-π, π].
    public static func wrappedDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    /// Shortest signed difference `a - b` in degrees, wrapped into (-180, 180].
    public static func wrappedDeltaDegrees(_ a: Double, _ b: Double) -> Double {
        degrees(wrappedDelta(radians(a), radians(b)))
    }

    public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}
