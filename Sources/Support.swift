import AppKit
import simd

// MARK: - Быстрый генератор случайных чисел для частиц

struct RNG {
    private var state: UInt64
    init(seed: UInt64 = UInt64(UInt32.random(in: 1...UInt32.max))) { state = seed | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// Число в диапазоне 0..<1.
    mutating func unit() -> Float { Float(next() >> 40) * (1.0 / 16_777_216.0) }
    mutating func range(_ r: ClosedRange<Float>) -> Float { r.lowerBound + (r.upperBound - r.lowerBound) * unit() }
    /// Число в диапазоне -1..<1.
    mutating func signed() -> Float { unit() * 2 - 1 }
}

// MARK: - Координаты
//
// Вся симуляция живёт в глобальных CG-координатах: начало — левый верхний угол основного
// экрана, y растёт вниз. В них же отдают рамки окон CGWindowList и экранов CGDisplayBounds.

enum Geo {
    /// Высота основного экрана (того, где строка меню).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Точка из координат Cocoa (y вверх) в глобальные CG-координаты.
    static func cg(_ p: NSPoint) -> SIMD2<Float> { SIMD2(Float(p.x), Float(primaryHeight - p.y)) }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Настройки

enum Intensity: Int, CaseIterable {
    case light, steady, blizzard

    var title: String {
        switch self {
        case .light: return "Снежок"
        case .steady: return "Снегопад"
        case .blizzard: return "Метель"
        }
    }
    /// Снежинок на миллион pt² экрана.
    var density: Float {
        switch self {
        case .light: return 210
        case .steady: return 480
        case .blizzard: return 1250
        }
    }
    /// Скорость падения, pt/с.
    var speed: ClosedRange<Float> {
        switch self {
        case .light: return 26...60
        case .steady: return 38...92
        case .blizzard: return 105...230
        }
    }
    /// Диаметр снежинки, pt.
    var size: ClosedRange<Float> {
        switch self {
        case .light: return 1.6...5.4
        case .steady: return 1.5...5.8
        case .blizzard: return 1.2...4.6
        }
    }
    /// Сила случайных порывов, pt/с.
    var gust: Float {
        switch self {
        case .light: return 10
        case .steady: return 18
        case .blizzard: return 75
        }
    }
}

enum Wind: Int, CaseIterable {
    case strongLeft = -2, left = -1, calm = 0, right = 1, strongRight = 2

    var title: String {
        switch self {
        case .strongLeft: return "Сильный влево"
        case .left: return "Слабый влево"
        case .calm: return "Штиль"
        case .right: return "Слабый вправо"
        case .strongRight: return "Сильный вправо"
        }
    }
    var speed: Float {
        switch self {
        case .strongLeft: return -150
        case .left: return -45
        case .calm: return 0
        case .right: return 45
        case .strongRight: return 150
        }
    }
}

enum Tool: Int {
    case none, mitten, sculpt
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "intensity": Intensity.steady.rawValue, "wind": 0, "gusts": true,
            "accumulate": true, "cursorPush": true, "paused": false,
        ])
    }

    var intensity: Intensity {
        get { Intensity(rawValue: d.integer(forKey: "intensity")) ?? .steady }
        set { d.set(newValue.rawValue, forKey: "intensity") }
    }
    var wind: Wind {
        get { Wind(rawValue: d.integer(forKey: "wind")) ?? .calm }
        set { d.set(newValue.rawValue, forKey: "wind") }
    }
    var gusts: Bool {
        get { d.bool(forKey: "gusts") }
        set { d.set(newValue, forKey: "gusts") }
    }
    var accumulate: Bool {
        get { d.bool(forKey: "accumulate") }
        set { d.set(newValue, forKey: "accumulate") }
    }
    var cursorPush: Bool {
        get { d.bool(forKey: "cursorPush") }
        set { d.set(newValue, forKey: "cursorPush") }
    }
    var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }
    /// Экономный режим вручную: 30 кадров, вдвое меньше снега, кадр в 1x.
    var eco: Bool {
        get { d.bool(forKey: "eco") }
        set { d.set(newValue, forKey: "eco") }
    }
    /// Инструмент не сохраняется: режим лепки перехватывает мышь, и после перезапуска
    /// экран не должен оказаться занятым.
    var tool: Tool = .none
}
