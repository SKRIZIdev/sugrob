import Foundation
import simd

/// Маленький погрузчик с ковшом. Приезжает справа раз в ~40 с и ~15 с убирает снег: едучи налево,
/// сгребает сугроб у нижней кромки в кучу фиксированного размера; набрал (или упёрся в пряничный домик) —
/// разворачивается, везёт к правому краю, опрокидывает ковш — снег летит за экран — и едет за следующей
/// порцией. Время вышло — отвозит последнюю порцию и уезжает за край.
/// Колёса крутятся, корпус наклоняется по неровностям сугроба, мигает маячок, из трубы дымок.
final class Excavator {
    enum Phase { case arriving, collecting, carrying, dumping, turning, leaving, resting, gone }

    private(set) var phase: Phase = .gone
    private var phaseT: Float = 0
    /// Глобальный x середины между колёсами.
    private(set) var x: Float = 0
    private var dir: Float = -1
    private var nextDir: Float = -1
    /// Сколько снега в ковше, pt².
    private(set) var load: Float = 0
    /// Фиксированный размер кучи: набрал — везёт выбрасывать.
    let capacity: Float = 1500
    /// Ковш крупнее машины «по чертежу».
    private let bucketSize: Float = 1.3
    /// Сколько длится одна уборка и как часто он приезжает.
    let workTime: Float = 15
    let visitEvery: Float = 40
    private var workLeft: Float = 0
    private var speed: Float = 24
    private var visitStart: Float = 0
    let scale: Float = 0.75
    private var clock: Float = 0
    private var wheel: Float = 0
    private var arm: Float = 0.35         // 0 — ковш у земли, 1 — поднят
    private var tilt: Float = -0.3        // наклон ковша: < 0 — назад (держит), > 0 — вперёд (высыпает)
    private var spilled: Float = 0
    private var enabled = false
    private var restFor: Float = 0
    private var rng = RNG(seed: 0xE5CA)

    // Связь с миром: верх сугроба под x; сгрести (x, полуширина, доля) → площадь; выбросить снежинку.
    var groundTop: ((Float) -> Float)?
    var carve: ((Float, Float, Float) -> Float)?
    var spill: ((SIMD2<Float>, SIMD2<Float>) -> Void)?
    /// Где можно ездить: края экрана и левая граница (справа от пряничного домика, если он есть).
    var bounds: (minX: Float, maxX: Float) = (0, 1000)
    var leftLimit: Float = 0

    var visible: Bool { phase != .gone && phase != .resting }
    var phaseName: String { "\(phase)" }
    var debugState: String { String(format: "x=%.0f груз=%.0f осталось=%.1fс скорость=%.0f", x, load, workLeft, speed) }
    private var half: Float { 30 * scale }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            guard phase == .gone || phase == .leaving || phase == .resting else { return }
            if phase != .leaving { x = bounds.maxX + half + 30 }
            dir = -1
            startVisit()
        } else if phase == .resting {
            go(.gone)
        } else if phase != .gone {
            dir = 1
            go(.leaving)
        }
    }

    /// Въехать прямо сейчас (для проверок).
    func comeBackNow() { if phase == .resting { restFor = 0 } }

    private func go(_ p: Phase) { phase = p; phaseT = 0 }

    private func startVisit() {
        workLeft = workTime
        visitStart = clock
        go(.arriving)
    }

    /// Шаг. Возвращает true, если надо перерисовать.
    func step(_ dt: Float) -> Bool {
        guard phase != .gone else { return false }
        if phase == .resting {
            phaseT += dt
            clock += dt
            if phaseT >= restFor { x = bounds.maxX + half + 30; dir = -1; startVisit() }
            return false
        }
        clock += dt
        phaseT += dt
        func drive(_ v: Float) {
            x += dir * v * dt
            wheel += dir * v * dt / (7 * scale)
        }
        func ease(_ cur: inout Float, _ to: Float, _ rate: Float) { cur += (to - cur) * min(1, dt * rate) }
        let lipReach = half + 12 * bucketSize * scale
        if phase == .collecting || phase == .carrying || phase == .dumping || phase == .turning { workLeft -= dt }
        let leftWall = max(bounds.minX, leftLimit)

        switch phase {
        case .arriving:
            ease(&arm, 0.35, 4); ease(&tilt, -0.3, 4)
            drive(42)
            if x < bounds.maxX - half - 24 { go(.collecting) }

        case .collecting:
            ease(&arm, 0, 5); ease(&tilt, 0, 5)
            drive(speed)
            // Ковш у земли снимает сугроб слоями перед собой, а не выкапывает яму в одном месте.
            // Где снега нет (уже расчищено) — едет быстрее, где есть — сбавляет ход и сгребает.
            var got: Float = 0
            if arm < 0.15, let carve {
                let lip = x + dir * lipReach
                got = carve(lip, 7.5 * bucketSize * scale, min(1, 24 * dt / 9))
                load = min(capacity, load + got)
            }
            ease(&speed, got / max(dt, 0.001) > 40 ? 30 : 60, 3)
            let atLeft = dir < 0 && x - lipReach <= leftWall + 2
            let atRight = dir > 0 && x + lipReach >= bounds.maxX - 2
            if load >= capacity || workLeft <= 0 {
                // Полный ковш или время вышло — к правому краю (пустым — просто уезжает).
                if load < 1 && workLeft <= 0 { dir = 1; go(.leaving) }
                else if dir > 0 { go(.carrying) } else { nextDir = 1; go(.turning) }
            } else if atLeft {
                nextDir = 1
                go(.turning)                      // упёрся в домик — разворачивается и сгребает обратно
            } else if atRight {
                go(load > 1 ? .dumping : .leaving)
            }

        case .carrying:
            ease(&arm, 0.55, 4); ease(&tilt, -0.5, 4)
            drive(70)
            let edge = dir > 0 ? x + lipReach >= bounds.maxX - 2 : x - lipReach <= bounds.minX + 2
            if edge { go(.dumping) }

        case .dumping:
            // Поднял ковш и опрокинул у самого края: снег летит за экран.
            ease(&arm, 0.95, 5)
            if phaseT > 0.25 { ease(&tilt, 1.35, 4) }
            if phaseT > 0.4 && load > 0 {
                let out = min(load, capacity * dt / 0.45)
                load -= out
                spilled += out
                while spilled >= 8 {
                    spilled -= 8
                    let lip = bucketLip()
                    spill?(lip, SIMD2(dir * rng.range(130...240), rng.range(-90 ... 10)))
                }
            }
            if phaseT > 1.2 {
                load = 0
                // Время ещё есть — за следующей порцией, иначе уезжает за край.
                if workLeft > 0 { nextDir = -1; go(.turning) } else { dir = 1; go(.leaving) }
            }

        case .turning:
            ease(&arm, 0.3, 4); ease(&tilt, -0.2, 4)
            if phaseT > 0.5 {
                dir = nextDir
                go(load >= capacity || (workLeft <= 0 && dir > 0) ? .carrying : .collecting)
            }

        case .leaving:
            ease(&arm, 0.35, 4); ease(&tilt, -0.3, 4)
            drive(enabled ? 45 : 70)
            if x > bounds.maxX + half + 40 || x < bounds.minX - half - 40 {
                load = 0
                // Следующий приезд — через ~40 с от начала этого.
                if enabled { restFor = max(8, visitEvery - (clock - visitStart)); go(.resting) } else { go(.gone) }
            }

        case .resting:
            // За экраном: отдыхает и въезжает снова справа.
            if phaseT >= restFor {
                x = bounds.maxX + half + 30
                dir = -1
                startVisit()
            }

        case .gone:
            break
        }
        if phase == .collecting || phase == .carrying { x = min(max(x, leftWall + half), bounds.maxX - half) }
        return true
    }

    // MARK: Геометрия

    /// Корпус: точка опоры (середина между колёсами на сугробе), вектор «вперёд» и «вверх».
    private func frame() -> (base: SIMD2<Float>, f: SIMD2<Float>, up: SIMD2<Float>) {
        let rearX = x - dir * 14 * scale, frontX = x + dir * 14 * scale
        let yR = groundTop?(rearX) ?? 0, yF = groundTop?(frontX) ?? 0
        // Крен по сугробу, но не больше ~11°: в собственной колее не заваливается.
        let run = frontX - rearX, lim = abs(run) * 0.2
        let f = simd_normalize(SIMD2<Float>(run, max(-lim, min(lim, yF - yR))))
        let up = f.x > 0 ? SIMD2<Float>(f.y, -f.x) : SIMD2<Float>(-f.y, f.x)
        return (SIMD2(x, (yR + yF) / 2), f, up)
    }

    /// Шарнир ковша и его наклон — в координатах машины (x вперёд, y вверх отрицательный).
    private var hinge: SIMD2<Float> { SIMD2(30 + 2 * arm, -8 - 22 * arm) }

    private func bucketPoint(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let c = cos(tilt), s = sin(tilt), q = p * bucketSize
        return hinge + SIMD2(q.x * c - q.y * s, q.x * s + q.y * c)
    }

    private func bucketLip() -> SIMD2<Float> {
        let fr = frame()
        let l = bucketPoint(SIMD2(15, 3))
        return fr.base + fr.f * (l.x * scale) + fr.up * (-l.y * scale)
    }

    // MARK: Отрисовка

    func draw(tris t: inout [TriVertex], points pt: inout [PointVertex]) {
        guard visible else { return }
        let fr = frame(), k = scale
        func P(_ p: SIMD2<Float>) -> SIMD2<Float> { fr.base + fr.f * (p.x * k) + fr.up * (-p.y * k) }
        func P(_ x: Float, _ y: Float) -> SIMD2<Float> { P(SIMD2(x, y)) }
        func quad(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>,
                  _ top: SIMD4<Float>, _ low: SIMD4<Float>) {
            t += [TriVertex(pos: P(a), color: top), TriVertex(pos: P(b), color: top), TriVertex(pos: P(c), color: low),
                  TriVertex(pos: P(a), color: top), TriVertex(pos: P(c), color: low), TriVertex(pos: P(d), color: low)]
        }
        func box(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ top: SIMD4<Float>, _ low: SIMD4<Float>) {
            quad(SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1), top, low)
        }
        func disc(_ c: SIMD2<Float>, _ r: Float, _ col: SIMD4<Float>) {
            let n = 16
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                t += [TriVertex(pos: P(c), color: col),
                      TriVertex(pos: P(c + SIMD2(cos(a0), sin(a0)) * r), color: col),
                      TriVertex(pos: P(c + SIMD2(cos(a1), sin(a1)) * r), color: col)]
            }
        }
        func bar(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ w: Float, _ col: SIMD4<Float>) {
            let d = simd_normalize(b - a), n = SIMD2<Float>(-d.y, d.x) * w / 2
            quad(a + n, b + n, b - n, a - n, col, col)
        }
        func dot(_ p: SIMD2<Float>, _ size: Float, _ c: SIMD3<Float>, _ kind: Float, _ alpha: Float = 1) {
            pt.append(PointVertex(pos: P(p), size: size * k, alpha: alpha, color: SIMD4(c, kind)))
        }

        let yellow = SIMD4<Float>(0.99, 0.78, 0.18, 1), yellowLow = SIMD4<Float>(0.90, 0.60, 0.08, 1)
        let deep = SIMD4<Float>(0.82, 0.52, 0.06, 1)
        let steel = SIMD4<Float>(0.50, 0.53, 0.58, 1), steelDark = SIMD4<Float>(0.34, 0.36, 0.41, 1)
        let tire = SIMD4<Float>(0.13, 0.13, 0.15, 1), hub = SIMD4<Float>(0.70, 0.71, 0.75, 1)

        // Выхлопная труба и дымок.
        box(-20, -31, -17, -23, steelDark, steelDark)
        for i in 0..<3 {
            let ph = (clock * 0.9 + Float(i) / 3).truncatingRemainder(dividingBy: 1)
            dot(SIMD2(-18.5 + ph * 4, -33 - ph * 14), 5 + ph * 8, SIMD3(0.80, 0.81, 0.85), 3, 0.35 * (1 - ph))
        }
        // Корпус: капот, рама, кабина с окном и крышей.
        box(-25, -24, -6, -15, yellow, yellowLow)
        box(-25, -16, 21, -8, yellow, yellowLow)
        box(-6, -38, 12, -15, yellow, yellowLow)
        box(-8, -41, 14, -37.5, deep, deep)
        box(-3, -35, 9.5, -22, SIMD4(0.78, 0.90, 0.98, 1), SIMD4(0.55, 0.74, 0.90, 1))
        bar(SIMD2(-1, -24), SIMD2(5, -34), 1.2, SIMD4(1, 1, 1, 0.55))
        // Стрела, гидроцилиндр и ковш.
        let h = hinge
        bar(SIMD2(13, -20), h, 3.6, deep)
        bar(SIMD2(8, -12), (SIMD2(13, -20) + h) / 2 + SIMD2(0, 2), 1.6, steel)
        let shape: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(0, 8), SIMD2(11, 9.5), SIMD2(15, 3), SIMD2(12, 2), SIMD2(3, 0)]
        let center = bucketPoint(SIMD2(7, 4.5))
        for i in 0..<shape.count {
            let a = bucketPoint(shape[i]), b = bucketPoint(shape[(i + 1) % shape.count])
            t += [TriVertex(pos: P(center), color: steel), TriVertex(pos: P(a), color: steelDark), TriVertex(pos: P(b), color: steelDark)]
        }
        // Куча снега в ковше растёт с загрузкой.
        if load > 1 {
            let q = min(1, load / capacity)
            let top = bucketPoint(SIMD2(7, 1.5))
            let w: Float = 7.5 * bucketSize, hh: Float = (2 + 7 * q) * bucketSize
            let snowTop = SIMD4<Float>(0.99, 0.99, 1.0, 1), snowLow = SIMD4<Float>(0.84, 0.88, 0.95, 1)
            let n = 12
            let c = cos(tilt), s = sin(tilt)
            func rot(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(v.x * c - v.y * s, v.x * s + v.y * c) }
            for i in 0..<n {
                let a0 = Float.pi + Float.pi * Float(i) / Float(n), a1 = Float.pi + Float.pi * Float(i + 1) / Float(n)
                t += [TriVertex(pos: P(top), color: snowLow),
                      TriVertex(pos: P(top + rot(SIMD2(cos(a0) * w, sin(a0) * hh))), color: snowTop),
                      TriVertex(pos: P(top + rot(SIMD2(cos(a1) * w, sin(a1) * hh))), color: snowTop)]
            }
        }
        // Колёса с вращающимися дисками.
        for cx in [Float(-14), 14] {
            let c = SIMD2<Float>(cx, -7)
            disc(c, 7, tire)
            disc(c, 3.2, hub)
            for j in 0..<3 {
                let a = wheel + Float(j) * 2 * .pi / 3
                dot(c + SIMD2(cos(a), sin(a)) * 1.7, 1.3, SIMD3(0.35, 0.36, 0.40), 2)
            }
        }
        // Маячок на крыше мигает.
        let blink = max(0, sin(clock * 6))
        dot(SIMD2(3, -42.5), 3.2, SIMD3(1.0, 0.55, 0.12), 2)
        dot(SIMD2(3, -42.5), 16, SIMD3(1.0, 0.55, 0.12), 3, 0.15 + 0.45 * blink)
    }
}
