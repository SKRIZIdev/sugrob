import Foundation
import simd

/// Пряничный домик с ёлкой в левом нижнем углу экрана. Окна теплятся (огонь чуть мерцает), из трубы
/// идёт дым, на ёлке мигает гирлянда и светится звезда. Скаты крыши и труба — настоящие кромки:
/// на них копится снег. Появляется по очереди с пружинящим «перелётом», исчезает, сжимаясь.
///
/// Координаты сцены — в точках от левого нижнего угла стены домика (y вверх — отрицательный),
/// на экран их переводит `anchor`.
final class GingerbreadScene {
    struct Puff { var x, y, vx, vy, age, life, s0, s1, phase: Float }

    private(set) var enabled = false
    private var dying = false
    private var t: Float = 0            // время с включения
    private var fade: Float = 1         // 1 → 0 при выключении
    private var clock: Float = 0
    private var puffs: [Puff] = []
    private var puffTimer: Float = 0
    private var rng = RNG(seed: 0x51A9)
    private var wasSolid = false

    // Скаты крыши: от карниза до конька 69 pt по горизонтали, уклон 56/69.
    static let pitch: Float = 56.0 / 69.0
    let roofLeft = Heightmap(width: 69, maxH: 9)
    let roofRight = Heightmap(width: 69, maxH: 9)
    let chimneyTop = Heightmap(width: 20, maxH: 6, endRadius: 5)

    /// Дорос и не исчезает — крыша принимает снег.
    var solid: Bool { enabled && !dying && t > 1.0 }
    /// Есть что рисовать.
    var visible: Bool { (enabled && fade > 0) || !puffs.isEmpty }

    func setEnabled(_ on: Bool) {
        if on {
            if !enabled || dying { enabled = true; dying = false; t = 0; fade = 1 }
        } else if enabled {
            dying = true
        }
    }

    func clearSnow() { roofLeft.clear(); roofRight.clear(); chimneyTop.clear() }

    /// Шаг сцены. `active` — нужна перерисовка, `solidChanged` — крыша стала/перестала быть кромкой.
    func step(_ dt: Float, wind: Float) -> (active: Bool, solidChanged: Bool) {
        clock += dt
        if enabled {
            t += dt
            if dying {
                fade = max(0, fade - dt / 0.45)
                if fade == 0 { enabled = false; dying = false }
            }
        }
        // Дым: клуб раз в ~0.11 с, пока домик стоит.
        if enabled && !dying && t > 1.0 {
            puffTimer -= dt
            while puffTimer <= 0 {
                puffTimer += rng.range(0.09...0.14)
                puffs.append(Puff(x: 84 + rng.signed() * 2, y: -146, vx: rng.signed() * 6, vy: -rng.range(24...32),
                                  age: 0, life: rng.range(3.6...5.0), s0: rng.range(6...8), s1: rng.range(30...40),
                                  phase: rng.unit() * 6.283))
            }
        }
        var w = 0
        for i in puffs.indices {
            var p = puffs[i]
            p.age += dt
            guard p.age < p.life else { continue }
            // Клуб поднимается, слегка замедляясь, закручивается и сносится ветром.
            let target = wind * 0.3 + sin(p.phase + p.age * 1.1) * 9
            p.vx += (target - p.vx) * min(1, dt * 0.9)
            p.vy *= 1 - 0.05 * dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            puffs[w] = p
            w += 1
        }
        puffs.removeLast(puffs.count - w)
        let s = solid
        defer { wasSolid = s }
        return (visible, s != wasSolid)
    }

    /// Кромки сцены в глобальных координатах.
    func surfaces(anchor o: SIMD2<Float>) -> [Surface] {
        guard solid else { return [] }
        return [
            Surface(a: o.x - 14, b: o.x + 55, y: o.y - 64, originX: o.x - 14, map: roofLeft, window: nil, slope: -Self.pitch),
            Surface(a: o.x + 55, b: o.x + 124, y: o.y - 120, originX: o.x + 55, map: roofRight, window: nil, slope: Self.pitch),
            Surface(a: o.x + 74, b: o.x + 94, y: o.y - 142, originX: o.x + 74, map: chimneyTop, window: nil),
        ]
    }

    // MARK: Отрисовка

    private static func easeOutBack(_ x: Float) -> Float {
        let t = min(max(x, 0), 1) - 1
        return 1 + 2.70158 * t * t * t + 1.70158 * t * t
    }

    /// Насколько вырос объект: появляется через `delay` за `dur` с перелётом; при выключении — сжимается.
    private func level(_ delay: Float, _ dur: Float) -> Float {
        if dying { let f = fade; return f * f }
        return GingerbreadScene.easeOutBack((t - delay) / dur)
    }

    func draw(anchor o: SIMD2<Float>, tris: inout [TriVertex], points: inout [PointVertex]) {
        if enabled {
            let house = level(0, 0.7)
            let tree = level(0.25, 0.7)
            let star = level(0.75, 0.45)
            let lights = dying ? fade : min(1, max(0, (t - 0.9) / 0.4))
            let fence = level(0.45, 0.6)
            if fence > 0.01 { drawFence(o, fence, &tris, &points) }
            if house > 0.01 { drawHouse(o, house, &tris, &points) }
            if tree > 0.01 { drawTree(o, tree, star, lights, &tris, &points) }
        }
        for p in puffs {
            let k = p.age / p.life
            let size = p.s0 + (p.s1 - p.s0) * (1 - (1 - k) * (1 - k))
            let alpha = 0.4 * min(1, p.age / 0.35) * pow(1 - k, 1.4)
            points.append(PointVertex(pos: o + SIMD2(p.x, p.y), size: size, alpha: alpha, color: SIMD4(0.92, 0.93, 0.96, 3)))
        }
    }

    // Цвета
    private let gingerTop = SIMD4<Float>(0.80, 0.50, 0.27, 1), gingerLow = SIMD4<Float>(0.62, 0.36, 0.18, 1)
    private let choco = SIMD4<Float>(0.42, 0.22, 0.12, 1), chocoDark = SIMD4<Float>(0.33, 0.17, 0.09, 1)
    private let icing = SIMD4<Float>(0.99, 0.98, 0.96, 1)
    private let icingRGB = SIMD3<Float>(0.99, 0.98, 0.96)
    private let glassTop = SIMD4<Float>(1.0, 0.89, 0.55, 1), glassLow = SIMD4<Float>(0.98, 0.64, 0.25, 1)
    private let warm = SIMD3<Float>(1.0, 0.70, 0.32)

    private func drawHouse(_ o: SIMD2<Float>, _ s: Float, _ t: inout [TriVertex], _ pt: inout [PointVertex]) {
        // Растёт от середины основания.
        let pivot = SIMD2<Float>(55, 0)
        func P(_ x: Float, _ y: Float) -> SIMD2<Float> { o + pivot + (SIMD2(x, y) - pivot) * s }
        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ top: SIMD4<Float>, _ low: SIMD4<Float>) {
            quad(&t, P(x0, y0), P(x1, y0), P(x1, y1), P(x0, y1), top, top, low, low)
        }
        func disc(_ cx: Float, _ cy: Float, _ r: Float, _ c: SIMD4<Float>, _ from: Float = 0, _ to: Float = 2 * .pi) {
            let n = 18
            for k in 0..<n {
                let a0 = from + (to - from) * Float(k) / Float(n), a1 = from + (to - from) * Float(k + 1) / Float(n)
                t.append(TriVertex(pos: P(cx, cy), color: c))
                t.append(TriVertex(pos: P(cx + cos(a0) * r, cy + sin(a0) * r), color: c))
                t.append(TriVertex(pos: P(cx + cos(a1) * r, cy + sin(a1) * r), color: c))
            }
        }
        func dot(_ x: Float, _ y: Float, _ size: Float, _ c: SIMD3<Float>, kind: Float, alpha: Float = 1) {
            pt.append(PointVertex(pos: P(x, y), size: size * s, alpha: alpha, color: SIMD4(c, kind)))
        }
        let flicker = 0.85 + 0.09 * sin(clock * 7.3) + 0.06 * sin(clock * 13.1 + 1.7)

        // Труба — за крышей.
        rect(74, -142, 94, -136, icing, icing)
        rect(76, -137, 92, -96, SIMD4(0.68, 0.28, 0.21, 1), SIMD4(0.55, 0.22, 0.17, 1))
        // Стены и фронтон.
        rect(0, -70, 110, 0, gingerTop, gingerLow)
        t.append(TriVertex(pos: P(0, -70), color: gingerTop))
        t.append(TriVertex(pos: P(110, -70), color: gingerTop))
        t.append(TriVertex(pos: P(55, -116), color: SIMD4(0.85, 0.56, 0.31, 1)))
        // Окна: глазурь-рамка, тёплое стекло, переплёт.
        for x0 in [Float(12), 76] {
            rect(x0 - 3, -55, x0 + 25, -27, icing, icing)
            rect(x0, -52, x0 + 22, -30, glassTop, glassLow)
            rect(x0 + 10.2, -52, x0 + 11.8, -30, icing, icing)
            rect(x0, -41.8, x0 + 22, -40.2, icing, icing)
        }
        // Круглое окошко на фронтоне.
        disc(55, -90, 10, icing)
        disc(55, -90, 7.5, glassTop)
        rect(54.3, -97.5, 55.7, -82.5, icing, icing)
        rect(47.5, -90.7, 62.5, -89.3, icing, icing)
        // Дверь с полукруглым верхом в рамке из глазури.
        rect(41.5, -25, 68.5, 0, icing, icing)
        disc(55, -25, 13.5, icing, .pi, 2 * .pi)
        let door = SIMD4<Float>(0.72, 0.18, 0.20, 1), doorLow = SIMD4<Float>(0.56, 0.12, 0.14, 1)
        rect(44, -25, 66, 0, door, doorLow)
        disc(55, -25, 11, door, .pi, 2 * .pi)
        // Скаты крыши — шоколадные полосы с конька к карнизам.
        roofBand(&t, P(-14, -64), P(55, -120), outward: SIMD2(-0.630, -0.776) * s, thick: 11 * s)
        roofBand(&t, P(55, -120), P(124, -64), outward: SIMD2(0.630, -0.776) * s, thick: 11 * s)
        disc(55, -118, 7, choco)
        // Леденцовая трость у двери: полоски и крючок.
        for k in 0..<8 {
            let y0 = -Float(k) * 3.6
            rect(37.5, y0 - 3.6, 40.5, y0, k % 2 == 0 ? SIMD4(0.90, 0.16, 0.20, 1) : icing, k % 2 == 0 ? SIMD4(0.80, 0.12, 0.16, 1) : icing)
        }
        for k in 0..<7 {
            let a0 = Float(k) / 7 * .pi, a1 = Float(k + 1) / 7 * .pi
            let c = k % 2 == 0 ? SIMD4<Float>(0.90, 0.16, 0.20, 1) : icing
            let p0 = SIMD2<Float>(36 + cos(a0) * 3, -28.8 - sin(a0) * 3), p1 = SIMD2<Float>(36 + cos(a1) * 3, -28.8 - sin(a1) * 3)
            let n0 = SIMD2<Float>(cos(a0), -sin(a0)) * 1.5, n1 = SIMD2<Float>(cos(a1), -sin(a1)) * 1.5
            quad(&t, P((p0 + n0).x, (p0 + n0).y), P((p1 + n1).x, (p1 + n1).y), P((p1 - n1).x, (p1 - n1).y), P((p0 - n0).x, (p0 - n0).y), c, c, c, c)
        }

        // Свет из окон и отсвет на снегу.
        for cx in [Float(23), 87] {
            dot(cx, -41, 72, warm, kind: 3, alpha: 0.32 * flicker)
            dot(cx, -3, 64, warm, kind: 3, alpha: 0.16 * flicker)
        }
        dot(55, -90, 40, warm, kind: 3, alpha: 0.26 * flicker)
        dot(55, -14, 30, warm, kind: 3, alpha: 0.10 * flicker)
        // Глазурь фестонами по нижнему краю скатов и капельки.
        for (a, b, inward) in [(SIMD2<Float>(-14, -64), SIMD2<Float>(55, -120), SIMD2<Float>(0.630, 0.776)),
                               (SIMD2<Float>(55, -120), SIMD2<Float>(124, -64), SIMD2<Float>(-0.630, 0.776))] {
            let n = 11
            for k in 0...n {
                let q = a + (b - a) * (Float(k) / Float(n)) + inward * 11.5
                dot(q.x, q.y, 6.5, icingRGB, kind: 2)
                if k % 2 == 1 { dot(q.x + inward.x * 3, q.y + 4.5, 3.6, icingRGB, kind: 2) }
            }
        }
        // Глазурь по углам стен.
        for x in [Float(2.5), 107.5] {
            for k in 0..<8 { dot(x, -6 - Float(k) * 8, 3.6, icingRGB, kind: 2) }
        }
        // Мармеладки.
        let gum: [(Float, Float, SIMD3<Float>)] = [
            (-9, -60, SIMD3(0.20, 0.70, 0.35)), (119, -60, SIMD3(0.92, 0.22, 0.30)), (55, -129, SIMD3(0.98, 0.78, 0.25)),
            (30, -78, SIMD3(0.95, 0.45, 0.65)), (80, -78, SIMD3(0.35, 0.75, 0.80)), (6, -64, SIMD3(0.98, 0.78, 0.25)),
            (104, -64, SIMD3(0.20, 0.70, 0.35)),
        ]
        for g in gum { dot(g.0, g.1, 7.5, g.2, kind: 4) }
        // Венок с бантом и дверная ручка.
        for k in 0..<12 {
            let a = Float(k) / 12 * 2 * .pi
            dot(55 + cos(a) * 6.5, -27 + sin(a) * 6.5, 4.6, SIMD3(0.16, 0.50, 0.26), kind: 4)
        }
        dot(55, -21, 3.4, SIMD3(0.90, 0.16, 0.20), kind: 4)
        dot(52.2, -21.6, 3.0, SIMD3(0.90, 0.16, 0.20), kind: 4)
        dot(57.8, -21.6, 3.0, SIMD3(0.90, 0.16, 0.20), kind: 4)
        dot(62, -12, 4.2, SIMD3(0.98, 0.80, 0.35), kind: 4)
    }

    private func drawTree(_ o: SIMD2<Float>, _ s: Float, _ starLevel: Float, _ lights: Float,
                          _ t: inout [TriVertex], _ pt: inout [PointVertex]) {
        let pivot = SIMD2<Float>(176, 0)
        func P(_ x: Float, _ y: Float) -> SIMD2<Float> { o + pivot + (SIMD2(x, y) - pivot) * s }
        func dot(_ x: Float, _ y: Float, _ size: Float, _ c: SIMD3<Float>, kind: Float, alpha: Float = 1) {
            pt.append(PointVertex(pos: P(x, y), size: size * s, alpha: alpha, color: SIMD4(c, kind)))
        }
        // Ствол.
        quad(&t, P(171, -14), P(181, -14), P(181, 0), P(171, 0),
             SIMD4(0.40, 0.24, 0.13, 1), SIMD4(0.40, 0.24, 0.13, 1), SIMD4(0.32, 0.18, 0.10, 1), SIMD4(0.32, 0.18, 0.10, 1))
        // Ярусы снизу вверх: (низ, полуширина, макушка).
        let tiers: [(Float, Float, Float)] = [(-10, 44, -62), (-44, 35, -92), (-74, 26, -120)]
        let deep = SIMD4<Float>(0.06, 0.30, 0.17, 1), light = SIMD4<Float>(0.17, 0.52, 0.29, 1)
        for (base, half, apex) in tiers {
            t.append(TriVertex(pos: P(176, apex), color: light))
            t.append(TriVertex(pos: P(176 - half, base), color: deep))
            t.append(TriVertex(pos: P(176 + half, base), color: deep))
            // Лапы — зубцами по нижнему краю.
            let teeth = 6
            for k in 0..<teeth {
                let x0 = 176 - half + 2 * half * Float(k) / Float(teeth), x1 = 176 - half + 2 * half * Float(k + 1) / Float(teeth)
                t.append(TriVertex(pos: P(x0, base - 0.5), color: deep))
                t.append(TriVertex(pos: P(x1, base - 0.5), color: deep))
                t.append(TriVertex(pos: P((x0 + x1) / 2, base + 5), color: deep))
            }
        }
        // Снег на лапах: белые комочки вдоль скатов ярусов и на кончиках.
        var r = RNG(seed: 0xE1C)
        for (base, half, apex) in tiers {
            for side in [Float(-1), 1] {
                for k in 0..<6 {
                    let u = 0.22 + 0.13 * Float(k)
                    let x = 176 + side * half * u, y = apex + (base - apex) * u - 1.5
                    dot(x + side * 0.8, y, r.range(4.5...7.5), SIMD3(0.97, 0.98, 1.0), kind: 2)
                }
                dot(176 + side * half * 0.97, base + 1, r.range(5...7), SIMD3(0.97, 0.98, 1.0), kind: 2)
            }
            dot(176, apex + 3, 5.5, SIMD3(0.97, 0.98, 1.0), kind: 2)
        }
        // Шарики.
        let balls: [(Float, Float, SIMD3<Float>)] = [
            (160, -22, SIMD3(0.86, 0.15, 0.20)), (192, -26, SIMD3(0.98, 0.78, 0.30)), (176, -36, SIMD3(0.25, 0.45, 0.90)),
            (150, -16, SIMD3(0.95, 0.45, 0.65)), (202, -15, SIMD3(0.85, 0.87, 0.93)), (166, -56, SIMD3(0.98, 0.78, 0.30)),
            (188, -60, SIMD3(0.86, 0.15, 0.20)), (176, -80, SIMD3(0.95, 0.45, 0.65)), (168, -98, SIMD3(0.25, 0.45, 0.90)),
            (185, -96, SIMD3(0.98, 0.78, 0.30)),
        ]
        for b in balls { dot(b.0, b.1, 6.5, b.2, kind: 4) }
        // Гирлянда: огоньки мигают каждый в своём ритме.
        if lights > 0 {
            let colors: [SIMD3<Float>] = [SIMD3(1.0, 0.86, 0.55), SIMD3(1.0, 0.35, 0.35), SIMD3(0.45, 1.0, 0.55),
                                          SIMD3(0.45, 0.65, 1.0), SIMD3(1.0, 0.85, 0.30)]
            var k = 0
            for (base, half, apex) in tiers {
                for j in 0..<5 {
                    let u = Float(j) / 4
                    let x = 176 - half * 0.75 + half * 1.5 * u
                    let y = apex + (base - apex) * (0.55 + 0.25 * u)
                    let c = colors[k % colors.count]
                    let tw = 0.45 + 0.55 * (0.5 + 0.5 * sin(clock * 2.6 + Float(k) * 1.7))
                    dot(x, y, 14, c, kind: 3, alpha: 0.55 * tw * lights)
                    dot(x, y, 3.2, c * 0.5 + 0.5, kind: 2, alpha: lights)
                    k += 1
                }
            }
        }
        // Звезда.
        if starLevel > 0.01 {
            let cx: Float = 176, cy: Float = -126
            let pulse = 0.30 + 0.08 * sin(clock * 2.1)
            pt.append(PointVertex(pos: P(cx, cy), size: 48 * s * starLevel, alpha: pulse, color: SIMD4(1.0, 0.85, 0.40, 3)))
            let center = SIMD4<Float>(1.0, 0.93, 0.58, 1), tip = SIMD4<Float>(0.98, 0.74, 0.22, 1)
            for k in 0..<5 {
                let a = -Float.pi / 2 + Float(k) * 2 * .pi / 5
                let outer = SIMD2<Float>(cos(a), sin(a)) * 11 * starLevel
                let l = SIMD2<Float>(cos(a - .pi / 5), sin(a - .pi / 5)) * 4.6 * starLevel
                let rr = SIMD2<Float>(cos(a + .pi / 5), sin(a + .pi / 5)) * 4.6 * starLevel
                t.append(TriVertex(pos: P(cx, cy), color: center))
                t.append(TriVertex(pos: P(cx + l.x, cy + l.y), color: center))
                t.append(TriVertex(pos: P(cx + outer.x, cy + outer.y), color: tip))
                t.append(TriVertex(pos: P(cx, cy), color: center))
                t.append(TriVertex(pos: P(cx + outer.x, cy + outer.y), color: tip))
                t.append(TriVertex(pos: P(cx + rr.x, cy + rr.y), color: center))
            }
        }
    }

    /// Участок: пряничный заборчик справа от ёлки — штакетины с глазурью на остриях, две перекладины.
    private func drawFence(_ o: SIMD2<Float>, _ s: Float, _ t: inout [TriVertex], _ pt: inout [PointVertex]) {
        let pivot = SIMD2<Float>(262, 0)
        func P(_ x: Float, _ y: Float) -> SIMD2<Float> { o + pivot + (SIMD2(x, y) - pivot) * s }
        let wood = SIMD4<Float>(0.76, 0.47, 0.25, 1), woodLow = SIMD4<Float>(0.60, 0.35, 0.18, 1)
        // Перекладины — за штакетинами.
        for y in [Float(-9), -20] {
            quad(&t, P(222, y - 3), P(302, y - 3), P(302, y + 1), P(222, y + 1), wood, wood, woodLow, woodLow)
        }
        for k in 0..<6 {
            let x = 224 + Float(k) * 15
            quad(&t, P(x, -26), P(x + 8, -26), P(x + 8, 0), P(x, 0), wood, wood, woodLow, woodLow)
            t.append(TriVertex(pos: P(x, -26), color: wood))
            t.append(TriVertex(pos: P(x + 8, -26), color: wood))
            t.append(TriVertex(pos: P(x + 4, -33), color: SIMD4(0.82, 0.53, 0.29, 1)))
            // Глазурь на острие и снежок на нём.
            pt.append(PointVertex(pos: P(x + 4, -31), size: 5.5 * s, alpha: 1, color: SIMD4(icingRGB, 2)))
            pt.append(PointVertex(pos: P(x + 4, -16), size: 3.2 * s, alpha: 1, color: SIMD4(0.90, 0.16, 0.20, 4)))
        }
    }

    /// Скат крыши: шоколадная полоса толщиной `thick` под внешней линией a→b.
    private func roofBand(_ t: inout [TriVertex], _ a: SIMD2<Float>, _ b: SIMD2<Float>, outward: SIMD2<Float>, thick: Float) {
        let inward = -simd_normalize(outward) * thick
        quad(&t, a, b, b + inward, a + inward, choco, choco, chocoDark, chocoDark)
    }

    private func quad(_ t: inout [TriVertex], _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>,
                      _ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        t.append(TriVertex(pos: p0, color: c0)); t.append(TriVertex(pos: p1, color: c1)); t.append(TriVertex(pos: p2, color: c2))
        t.append(TriVertex(pos: p0, color: c0)); t.append(TriVertex(pos: p2, color: c2)); t.append(TriVertex(pos: p3, color: c3))
    }
}
