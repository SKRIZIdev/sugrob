import AppKit
import simd

struct Flake {
    var x: Float, y: Float
    var vx: Float, vy: Float
    var fall: Float            // скорость падения в покое
    var size: Float            // диаметр, pt
    var phase: Float, swayFreq: Float, swayAmp: Float
    var resp: Float            // насколько сильно сносит ветром
    var stick: Float           // шанс осесть, пересекая поверхность
    var alpha: Float
}

/// Снег на верхней кромке одного окна (или Dock).
final class Cap {
    var frame: CGRect
    let map: Heightmap
    var lastSeen: Double
    var lastSync: Double
    var visible = true
    var spill: Float = 0
    init(frame: CGRect, maxH: Float, now: Double) {
        self.frame = frame
        map = Heightmap(width: Float(frame.width), maxH: maxH)
        lastSeen = now
        lastSync = now
    }
}

/// Видимый участок кромки, на который может лечь снег.
struct Surface {
    var a: Float, b: Float      // видимый отрезок по x
    var y: Float                // кромка
    var originX: Float          // x начала профиля
    let map: Heightmap
    var window: CGWindowID?     // nil — земля или Dock
    var isDock = false

    @inline(__always) func top(at x: Float) -> Float { y - map.height(at: x - originX) }
}

struct Ball {
    let id: Int
    var x: Float, y: Float
    var area: Float
    var vy: Float = 0
    var held = false, rolling = false, resting = false
    var window: CGWindowID? = nil
    var onDock = false          // стоит на Dock (сам или в стопке) — рисуется слоем Dock
    var off = SIMD2<Float>(0, 0)
    var grab = SIMD2<Float>(0, 0)
    var r: Float { (area / .pi).squareRoot() }
    var pos: SIMD2<Float> { SIMD2(x, y) }
}

final class ScreenArea {
    let id: CGDirectDisplayID
    let bounds: CGRect
    var flakes: [Flake] = []
    let ground: Heightmap
    var surfaces: [Surface] = []
    var spawnBudget: Float = 0

    init(id: CGDirectDisplayID, bounds: CGRect) {
        self.id = id
        self.bounds = bounds
        ground = Heightmap(width: Float(bounds.width), maxH: 14)
    }
    var groundSurface: Surface {
        Surface(a: Float(bounds.minX), b: Float(bounds.maxX), y: Float(bounds.maxY),
                originX: Float(bounds.minX), map: ground, window: nil)
    }
}

struct FrameRanges { var caps = 0, balls = 0, decor = 0 }

final class SnowWorld {
    let settings = Settings.shared
    private(set) var areas: [ScreenArea] = []
    private var caps: [CGWindowID: Cap] = [:]
    private var order: [CGWindowID] = []
    private var dock: Cap?
    private var dockTarget: CGRect?      // где Dock по Accessibility; спрятанный — за нижней кромкой
    private weak var dockArea: ScreenArea?
    private var dockTop: Float = 0       // где верх Dock нарисован сейчас
    private var dockRaised = false       // снег сейчас на крыше Dock, а не у кромки под ним
    /// Dock на экране (выехал или едет) — его надо опрашивать каждый кадр.
    var dockShown: Bool { dock?.visible == true }
    /// Где Dock нарисован сейчас и сколько снега на нём (для проверок).
    var dockState: (frame: CGRect, snow: Float)? { dock.map { ($0.frame, $0.map.total) } }
    private(set) var surfaces: [Surface] = []
    private(set) var balls: [Ball] = []
    private var rng = RNG()
    private var gust: Float = 0, gustTarget: Float = 0, gustTimer: Float = 0

    var mouse = SIMD2<Float>(-1e5, -1e5)
    var mouseVel = SIMD2<Float>(0, 0)
    var eco = false
    var depositBoost: Float = 1
    private(set) var needsRedraw = true
    private var changed = true
    private var heldID: Int?
    private var nextBallID = 1
    private var rollSurface: Surface?

    // MARK: Экраны и окна

    func setScreens(_ list: [(CGDirectDisplayID, CGRect)]) {
        areas = list.map { id, b in areas.first(where: { $0.id == id && $0.bounds == b }) ?? ScreenArea(id: id, bounds: b) }
        rebuildSurfaces()
        changed = true
    }

    /// Окна спереди назад. Возвращает true, если что-то сдвинулось или поменялся состав.
    @discardableResult
    func syncWindows(_ list: [TrackedWindow], now: Double) -> Bool {
        var moved = false
        var ids: [CGWindowID] = []
        ids.reserveCapacity(list.count)
        for w in list {
            ids.append(w.id)
            if let cap = caps[w.id] {
                let old = cap.frame
                if old != w.frame {
                    moved = true
                    if abs(old.width - w.frame.width) > 0.5 { cap.map.resize(width: Float(w.frame.width)) }
                    let dt = max(now - cap.lastSync, 1.0 / 120)
                    let vx = Float((w.frame.minX - old.minX) / dt), vy = Float((w.frame.minY - old.minY) / dt)
                    cap.frame = w.frame
                    // Сколько снега слетает — по времени, а не по числу опросов: пока окно тащат,
                    // опрос идёт каждый кадр. 300 pt/с за секунду сбрасывают ~40%, рывок — почти всё.
                    let speed = (vx * vx + vy * vy).squareRoot()
                    let rate = max(0, speed - 180) / 250
                    if cap.visible, rate > 0 {
                        shake(cap, vx: vx, vy: vy, fraction: min(0.6, 1 - exp(-rate * Float(dt))))
                    }
                }
                if !cap.visible { cap.visible = true; moved = true }
                cap.lastSeen = now
                cap.lastSync = now
            } else {
                caps[w.id] = Cap(frame: w.frame, maxH: w.kind == .widget ? 12 : 16, now: now)
                moved = true
            }
        }
        if ids != order { order = ids; moved = true }
        let seen = Set(ids)
        for (id, cap) in caps where !seen.contains(id) {
            if cap.visible { cap.visible = false; moved = true }
            // Окно на другом рабочем столе или свёрнуто — снег помним полчаса.
            if now - cap.lastSeen > 1800 { caps[id] = nil }
        }
        if moved { rebuildSurfaces(); changed = true }
        return moved
    }

    /// Свежая рамка Dock от Accessibility (nil — доступа нет или Dock не снизу).
    func setDock(_ frame: CGRect?, now: Double) {
        guard let f = frame, f.width > f.height,
              let a = areas.first(where: { $0.bounds.minX <= f.midX && f.midX < $0.bounds.maxX }) else {
            dockTarget = nil
            return
        }
        dockTarget = f
        if dock == nil || dockArea !== a {
            dock = Cap(frame: f, maxH: 12, now: now)
            dock?.visible = false
            dockArea = a
            dockTop = min(Float(f.minY), Float(a.bounds.maxY))
            dockRaised = false
        }
    }

    /// Dock со скрытием выезжает из-под нижней кромки: на старте он подхватывает сугроб, лежавший
    /// над ним, и везёт вверх; на подъёме часть снега крошится с краёв и подлетает. Прячется —
    /// снег едет вниз вместе с ним и у кромки снова ложится сугробом на то же место.
    private func stepDock(_ dt: Float) {
        guard let d = dock, let a = dockArea else { return }
        guard let f = dockTarget else {
            if d.visible { d.visible = false; rebuildSurfaces(); changed = true }
            return
        }
        let bottom = Float(a.bounds.maxY)
        let target = min(Float(f.minY), bottom)
        // Accessibility отдаёт каждый шаг анимации Dock (~раз в 10 мс) — идём за ним без сглаживания.
        let old = dockTop
        dockTop = target
        if abs(d.frame.width - f.width) > 0.5 { d.map.resize(width: Float(f.width)) }

        let shown = dockTop < bottom - 0.5
        if shown && !dockRaised {
            d.map.absorb(a.ground, offset: Float(f.minX - a.bounds.minX))
            dockRaised = true
        } else if !shown && dockRaised {
            a.ground.absorb(d.map, offset: Float(a.bounds.minX - f.minX))
            dockRaised = false
        }

        let frame = CGRect(x: f.minX, y: CGFloat(dockTop), width: f.width, height: f.height)
        guard frame != d.frame || d.visible != shown else { return }
        d.frame = frame
        d.visible = shown
        let vy = (dockTop - old) / max(dt, 0.001)
        let rate = max(0, abs(vy) - 150) / 400
        if shown, rate > 0 { shake(d, vx: 0, vy: vy, fraction: min(0.2, 1 - exp(-rate * dt))) }
        rebuildSurfaces()
        if shown { liftBalls() }
        changed = true
    }

    /// Dock выезжает из-под снеговика — поднимает его всей стопкой, а не проходит насквозь.
    private func liftBalls() {
        guard !balls.isEmpty, let s = surfaces.first(where: { $0.isDock }) else { return }
        var moved = Set<Int>()
        for i in balls.indices.sorted(by: { balls[$0].y > balls[$1].y }) {      // снизу вверх
            let b = balls[i]
            guard !b.held, !moved.contains(b.id), b.window == nil, b.x >= s.a, b.x <= s.b else { continue }
            let support = s.top(at: b.x) + min(b.r * 0.25, s.map.height(at: b.x - s.originX) * 0.6)
            let over = (b.y + b.r) - support
            guard over > 0.01 else { continue }
            for j in balls.indices where !balls[j].held && !moved.contains(balls[j].id)
                && abs(balls[j].x - b.x) < b.r && balls[j].y <= b.y {
                balls[j].y -= over
                balls[j].onDock = true
                moved.insert(balls[j].id)
            }
        }
    }


    /// Видимые участки кромок — только на них ложится снег.
    /// Поверх окон: кромку прячут окна спереди и Dock.
    /// За окнами: слой снега лежит под всеми окнами, поэтому шапку над кромкой прячет любое окно,
    /// виджет или Dock, занявшие полосу над ней, — снег виден только на открытом рабочем столе.
    func rebuildSurfaces() {
        let behind = !settings.overWindows
        var list: [Surface] = []
        var wins: [(CGWindowID, CGRect)] = []
        for id in order { if let c = caps[id], c.visible { wins.append((id, c.frame)) } }
        let dockFrame: CGRect? = dock?.visible == true ? dock?.frame : nil

        func segments(_ f: CGRect, hiddenBy occluders: [CGRect]) -> [(CGFloat, CGFloat)] {
            var segs: [(CGFloat, CGFloat)] = [(f.minX, f.maxX)]
            for c in occluders where c.minY <= f.minY + 1 && c.maxY >= f.minY - 20 {
                segs = SnowWorld.subtract(segs, c.minX, c.maxX)
                if segs.isEmpty { break }
            }
            return segs.filter { $0.1 - $0.0 > 3 }
        }

        if let d = dock, let df = dockFrame {
            // Снег на Dock рисуется своим слоем прямо над Dock — окна его не закрывают.
            list.append(Surface(a: Float(df.minX), b: Float(df.maxX), y: Float(df.minY),
                                originX: Float(df.minX), map: d.map, window: nil, isDock: true))
        }
        if settings.accumulate {
            var fronts: [CGRect] = dockFrame.map { [$0] } ?? []
            for (id, f) in wins {
                guard let cap = caps[id] else { continue }
                let occluders = behind ? (dockFrame.map { [$0] } ?? []) + wins.filter { $0.0 != id }.map { $0.1 } : fronts
                for s in segments(f, hiddenBy: occluders) {
                    list.append(Surface(a: Float(s.0), b: Float(s.1), y: Float(f.minY),
                                        originX: Float(f.minX), map: cap.map, window: id))
                }
                fronts.append(f)
            }
        }
        surfaces = list
        for a in areas {
            let x0 = Float(a.bounds.minX), x1 = Float(a.bounds.maxX)
            let y0 = Float(a.bounds.minY), y1 = Float(a.bounds.maxY)
            a.surfaces = list.filter { $0.b > x0 && $0.a < x1 && $0.y > y0 && $0.y < y1 }
        }
    }

    private static func subtract(_ segs: [(CGFloat, CGFloat)], _ a: CGFloat, _ b: CGFloat) -> [(CGFloat, CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        for (x0, x1) in segs {
            if b <= x0 || a >= x1 { out.append((x0, x1)); continue }
            if a > x0 { out.append((x0, a)) }
            if b < x1 { out.append((b, x1)) }
        }
        return out
    }

    // MARK: Шаг симуляции

    func step(dt rawDt: Float) {
        let dt = min(max(rawDt, 0.001), 0.05)
        updateWind(dt)
        stepDock(dt)
        let p = settings.intensity
        let wind = settings.wind.speed + gust
        var flakes = 0
        for a in areas {
            if !settings.paused { spawn(a, p, wind, dt) }
            if !a.flakes.isEmpty { updateFlakes(a, wind, dt) }
            flakes += a.flakes.count
        }
        if settings.tool == .mitten { sweep(dt) }
        relaxAll()
        let ballsActive = stepBalls(dt)
        needsRedraw = flakes > 0 || ballsActive || changed
        changed = false
    }

    private func updateWind(_ dt: Float) {
        gustTimer -= dt
        if gustTimer <= 0 {
            gustTimer = rng.range(2.5...7)
            let amp = settings.gusts ? settings.intensity.gust + abs(settings.wind.speed) * 0.35 : 0
            gustTarget = rng.signed() * amp
        }
        gust += (gustTarget - gust) * min(1, dt * 0.6)
    }

    private func spawn(_ a: ScreenArea, _ p: Intensity, _ wind: Float, _ dt: Float) {
        let mega = Float(a.bounds.width * a.bounds.height) / 1_000_000
        let target = p.density * mega * (eco ? 0.5 : 1)
        guard Float(a.flakes.count) < target * 1.25 else { a.spawnBudget = 0; return }
        let avgSpeed = (p.speed.lowerBound + p.speed.upperBound) / 2
        let life = Float(a.bounds.height) / avgSpeed
        // Ветер сносит снег вбок — рождаем его с запасом с наветренной стороны.
        let drift = wind * life * 0.8
        let x0 = Float(a.bounds.minX) - max(0, drift), x1 = Float(a.bounds.maxX) + max(0, -drift)
        let widen = (x1 - x0) / Float(a.bounds.width)
        a.spawnBudget += target / life * widen * dt
        let span = p.size.upperBound - p.size.lowerBound
        while a.spawnBudget >= 1 {
            a.spawnBudget -= 1
            let size = rng.range(p.size)
            let t = (size - p.size.lowerBound) / span           // 0 — мелкая и далёкая, 1 — крупная и близкая
            let fall = (p.speed.lowerBound + (p.speed.upperBound - p.speed.lowerBound) * (0.2 + 0.8 * t)) * rng.range(0.85...1.1)
            a.flakes.append(Flake(
                x: rng.range(x0...x1), y: Float(a.bounds.minY) - size - rng.unit() * 30,
                vx: wind, vy: fall, fall: fall, size: size,
                phase: rng.unit() * 6.283, swayFreq: rng.range(0.6...1.6), swayAmp: rng.range(4...15) * (1 - t * 0.5),
                resp: rng.range(0.75...1.1) * (1.15 - t * 0.4), stick: rng.range(0.25...0.6),
                alpha: rng.range(0.55...0.95) * (0.75 + 0.25 * t)))
        }
    }

    private func updateFlakes(_ a: ScreenArea, _ wind: Float, _ dt: Float) {
        let minX = Float(a.bounds.minX) - 260, maxX = Float(a.bounds.maxX) + 260
        let top = Float(a.bounds.minY) - 400
        let bottom = Float(a.bounds.maxY)
        let ground = a.groundSurface
        let push = settings.cursorPush
        let mr: Float = 60
        let k = min(1, dt * 1.8)
        let boost = depositBoost
        var fl: [Flake] = []
        swap(&fl, &a.flakes)
        var w = 0
        for r in 0..<fl.count {
            var f = fl[r]
            f.phase += f.swayFreq * dt
            f.vx += (wind * f.resp + sin(f.phase) * f.swayAmp - f.vx) * k
            f.vy += (f.fall - f.vy) * k
            if push {
                let dx = f.x - mouse.x, dy = f.y - mouse.y
                let d2 = dx * dx + dy * dy
                if d2 < mr * mr {
                    let d = max(d2.squareRoot(), 1), s = (1 - d / mr) * dt * 6
                    f.vx += (dx / d * 260 + mouseVel.x * 0.9) * s
                    f.vy += (dy / d * 260 + mouseVel.y * 0.9) * s
                }
            }
            let nx = f.x + f.vx * dt, ny = f.y + f.vy * dt
            if f.vy > 0 {
                var landed = false
                for s in a.surfaces where nx >= s.a && nx <= s.b {
                    let sy = s.top(at: nx)
                    if f.y <= sy && ny >= sy {
                        if rng.unit() < f.stick {
                            s.map.deposit(at: nx - s.originX, area: f.size * f.size * 0.4 * boost)
                            landed = true
                        }
                        break
                    }
                }
                if landed { continue }
                let gy = ground.top(at: nx)
                if f.y <= gy && ny >= gy && rng.unit() < f.stick * 1.3 {
                    ground.map.deposit(at: nx - ground.originX, area: f.size * f.size * 0.4 * boost)
                    continue
                }
            }
            f.x = nx
            f.y = ny
            if f.y > bottom + 8 || f.y < top || f.x < minX || f.x > maxX { continue }
            fl[w] = f
            w += 1
        }
        fl.removeLast(fl.count - w)
        fl.append(contentsOf: a.flakes)   // если кто-то успел добавить снежинки, пока массив был снят
        swap(&fl, &a.flakes)
    }

    private func relaxAll() {
        for cap in caps.values where cap.map.dirty {
            let (l, r) = cap.map.relax()
            changed = true
            guard cap.visible else { continue }
            cap.spill += l + r
            if cap.spill > 7 {
                let left = l >= r
                let x = Float(left ? cap.frame.minX : cap.frame.maxX) + (left ? -2 : 2)
                emit(x: x, y: Float(cap.frame.minY) - 2, vx: left ? -14 : 14, vy: 12, area: cap.spill, spread: 1.5)
                cap.spill = 0
            }
        }
        if let d = dock, d.map.dirty { d.map.relax(); changed = true }
        for a in areas where a.ground.dirty { a.ground.relax(edges: false); changed = true }
    }

    // MARK: Сброс снега

    /// Окно дёрнули — часть снега слетает, унося скорость окна.
    private func shake(_ cap: Cap, vx: Float, vy: Float, fraction frac: Float) {
        let map = cap.map
        let total = map.total
        guard total > 4, frac > 0.001 else { return }
        let removed = total * frac
        // Слетевший снег — снежинки; мелочь не плодим, она просто исчезает.
        let count = min(40, Int(removed / 7))
        guard count > 0 else { map.scale(1 - frac); changed = true; return }
        let step = max(1, map.h.count / count)
        let x0 = Float(cap.frame.minX), y0 = Float(cap.frame.minY)
        var i = Int(rng.unit() * Float(step))
        while i < map.h.count {
            if map.h[i] > 0.3 {
                emitOne(x: x0 + Float(i) * map.cell, y: y0 - map.h[i] * rng.unit(),
                        vx: vx * 0.45 + rng.signed() * 30, vy: min(vy * 0.45, 60) - 25 + rng.signed() * 20)
            }
            i += step
        }
        map.scale(1 - frac)
        changed = true
    }

    /// Курсор сметает снег («варежка»): снятое улетает по ходу движения.
    private func sweep(_ dt: Float) {
        let speed = simd_length(mouseVel)
        guard speed > 40 else { return }
        let radius: Float = 20
        let frac = min(1, dt * speed / 70)
        var all = surfaces
        for a in areas { all.append(a.groundSurface) }
        for s in all where mouse.x > s.a - radius && mouse.x < s.b + radius {
            let top = s.top(at: mouse.x)
            guard mouse.y > top - radius, mouse.y < s.y + 8 else { continue }
            let taken = s.map.carve(at: mouse.x - s.originX, halfWidth: radius, fraction: frac)
            if taken > 0.3 {
                changed = true
                emit(x: mouse.x, y: top, vx: mouseVel.x * 0.55, vy: min(mouseVel.y * 0.4, 0) - 35, area: taken, spread: radius)
            }
        }
        guard speed > 120 else { return }
        var i = balls.count - 1
        while i >= 0 {
            let b = balls[i]
            if simd_distance(b.pos, mouse) < b.r {
                emit(x: b.x, y: b.y, vx: mouseVel.x * 0.5, vy: -40, area: min(b.area * 0.5, 300), spread: b.r)
                balls.remove(at: i)
                changed = true
            }
            i -= 1
        }
    }

    /// Убрать весь снег: лежащий осыпается вниз и больше не цепляется.
    func shovel() {
        var all = surfaces
        for a in areas { all.append(a.groundSurface) }
        var budget = 500
        for s in all where budget > 0 {
            var x = s.a
            while x < s.b && budget > 0 {
                let h = s.map.height(at: x - s.originX)
                if h > 0.6 {
                    emitOne(x: x, y: s.y - h * rng.unit(), vx: rng.signed() * 20, vy: rng.range(-30...10), stick: 0)
                    budget -= 1
                }
                x += 7
            }
        }
        for b in balls where budget > 0 {
            emit(x: b.x, y: b.y, vx: 0, vy: -20, area: min(b.area * 0.3, 160), spread: b.r, stick: 0)
            budget -= 10
        }
        for c in caps.values { c.map.clear() }
        dock?.map.clear()
        for a in areas { a.ground.clear() }
        balls.removeAll()
        heldID = nil
        rollSurface = nil
        changed = true
    }

    private func area(containing x: Float, _ y: Float) -> ScreenArea? {
        areas.first { Float($0.bounds.minX) <= x && x < Float($0.bounds.maxX) && Float($0.bounds.minY) - 50 <= y && y < Float($0.bounds.maxY) }
            ?? areas.first { Float($0.bounds.minX) <= x && x < Float($0.bounds.maxX) }
    }

    private func emitOne(x: Float, y: Float, vx: Float, vy: Float, stick: Float = 0.18) {
        guard let a = area(containing: x, y) else { return }
        let fall = rng.range(70...120)
        a.flakes.append(Flake(x: x, y: y, vx: vx, vy: vy, fall: fall, size: rng.range(2.2...4.2),
                              phase: rng.unit() * 6.283, swayFreq: rng.range(0.8...1.6), swayAmp: rng.range(3...9),
                              resp: 0.8, stick: stick, alpha: rng.range(0.75...0.95)))
    }

    private func emit(x: Float, y: Float, vx: Float, vy: Float, area amount: Float, spread: Float = 6, stick: Float = 0.18) {
        let n = min(24, max(1, Int(amount / 7)))
        for _ in 0..<n {
            emitOne(x: x + rng.signed() * spread, y: y - rng.unit() * 3,
                    vx: vx + rng.signed() * 25, vy: vy + rng.signed() * 20, stick: stick)
        }
    }

    // MARK: Снежки и снеговики

    private func stepBalls(_ dt: Float) -> Bool {
        guard !balls.isEmpty else { return false }
        var active = false
        let floor = areas.map { Float($0.bounds.maxY) }.max() ?? 3000
        for i in balls.indices {
            if balls[i].held { active = true; continue }
            if balls[i].resting, let w = balls[i].window {
                if let cap = caps[w], cap.visible {
                    let nx = Float(cap.frame.minX) + balls[i].off.x, ny = Float(cap.frame.minY) + balls[i].off.y
                    if nx != balls[i].x || ny != balls[i].y { balls[i].x = nx; balls[i].y = ny; active = true }
                } else {
                    balls[i].resting = false
                    balls[i].window = nil
                }
            }
            let (support, win, dockSupport) = supportY(i)
            let r = balls[i].r
            if balls[i].resting {
                if support - r > balls[i].y + 1.5 {
                    balls[i].resting = false
                    balls[i].window = nil
                    balls[i].onDock = false
                } else { continue }
            }
            active = true
            balls[i].vy += 1500 * dt
            let ny = balls[i].y + balls[i].vy * dt
            if ny + r >= support {
                balls[i].y = support - r
                balls[i].vy = 0
                balls[i].resting = true
                balls[i].window = win
                balls[i].onDock = dockSupport
                if let w = win, let cap = caps[w] {
                    balls[i].off = SIMD2(balls[i].x - Float(cap.frame.minX), balls[i].y - Float(cap.frame.minY))
                }
            } else {
                balls[i].y = ny
            }
        }
        let before = balls.count
        balls.removeAll { !$0.held && $0.y > floor + 300 }
        if balls.count != before { changed = true }
        return active
    }

    /// Ближайшая опора под шаром i: кромка, сугроб у края экрана или другой шар.
    private func supportY(_ i: Int) -> (Float, CGWindowID?, Bool) {
        let b = balls[i], r = b.r
        let bottom = b.y + r
        var best = Float.greatestFiniteMagnitude
        var win: CGWindowID?
        var onDock = false
        for s in surfaces where b.x >= s.a && b.x <= s.b {
            let sy = s.top(at: b.x) + min(r * 0.25, s.map.height(at: b.x - s.originX) * 0.6)
            if sy >= bottom - 4 && sy < best { best = sy; win = s.window; onDock = s.isDock }
        }
        for a in areas where Float(a.bounds.minX) <= b.x && b.x < Float(a.bounds.maxX) {
            let g = a.groundSurface
            let sy = g.top(at: b.x) + min(r * 0.25, a.ground.height(at: b.x - g.originX) * 0.6)
            if sy >= bottom - 4 && sy < best { best = sy; win = nil; onDock = false }
        }
        for j in balls.indices where j != i && !balls[j].held && balls[j].resting {
            let o = balls[j]
            guard abs(o.x - b.x) < o.r * 0.85, o.y > b.y else { continue }
            let top = o.y - o.r * 0.9
            if top >= bottom - 4 && top < best { best = top; win = o.window; onDock = o.onDock }
        }
        return (best, win, onDock)
    }

    private func surfaceNear(_ p: SIMD2<Float>) -> Surface? {
        var all = surfaces
        for a in areas { all.append(a.groundSurface) }
        var best: Surface?
        var bestD = Float.greatestFiniteMagnitude
        for s in all where p.x >= s.a && p.x <= s.b {
            let top = s.top(at: p.x)
            guard p.y >= top - 28, p.y <= s.y + 10 else { continue }
            let d = abs(p.y - top)
            if d < bestD { bestD = d; best = s }
        }
        return best
    }

    func sculptDown(_ p: SIMD2<Float>) {
        if let i = balls.lastIndex(where: { simd_distance($0.pos, p) < $0.r + 3 }) {
            balls[i].held = true
            balls[i].rolling = false
            balls[i].resting = false
            balls[i].window = nil
            balls[i].onDock = false
            balls[i].vy = 0
            balls[i].grab = p - balls[i].pos
            heldID = balls[i].id
            changed = true
            return
        }
        guard let s = surfaceNear(p), s.map.height(at: p.x - s.originX) > 1.0 else { return }
        let area = max(s.map.carve(at: p.x - s.originX, halfWidth: 6, fraction: 0.75) * 1.3, Float.pi * 16)
        var b = Ball(id: nextBallID, x: p.x, y: 0, area: area)
        nextBallID += 1
        b.y = s.top(at: p.x) - b.r + min(b.r * 0.3, 3)
        b.held = true
        b.rolling = true
        balls.append(b)
        heldID = b.id
        rollSurface = s
        changed = true
    }

    func sculptDrag(_ p: SIMD2<Float>) {
        guard let id = heldID, let i = balls.firstIndex(where: { $0.id == id }) else { return }
        changed = true
        if balls[i].rolling, let s = rollSurface {
            let top = s.top(at: p.x)
            let lifted = p.y < top - balls[i].r * 2 - 24 || p.x < s.a - 8 || p.x > s.b + 8
            if !lifted {
                let dx = abs(p.x - balls[i].x)
                if dx > 0.01 {
                    let taken = s.map.carve(at: p.x - s.originX, halfWidth: max(3, balls[i].r * 0.75),
                                            fraction: min(0.9, dx / max(5, balls[i].r)))
                    balls[i].area = min(balls[i].area + taken * 1.3, .pi * 50 * 50)
                }
                balls[i].x = p.x
                balls[i].y = s.top(at: p.x) - balls[i].r + min(balls[i].r * 0.25, 3)
                return
            }
            balls[i].rolling = false
            balls[i].grab = p - balls[i].pos
        }
        balls[i].x = p.x - balls[i].grab.x
        balls[i].y = p.y - balls[i].grab.y
    }

    func sculptUp() {
        if let id = heldID, let i = balls.firstIndex(where: { $0.id == id }) {
            balls[i].held = false
            balls[i].rolling = false
            balls[i].vy = 0
        }
        heldID = nil
        rollSurface = nil
        changed = true
    }

    /// Для проверки отрисовки: присыпать все кромки и поставить снеговика.
    func demo() {
        for s in surfaces {
            var x = s.a
            while x < s.b { s.map.deposit(at: x - s.originX, area: 2.5 * 9); x += 2.5 }
        }
        for a in areas {
            var x = Float(a.bounds.minX)
            while x < Float(a.bounds.maxX) { a.ground.deposit(at: x - Float(a.bounds.minX), area: 2.5 * 8); x += 2.5 }
        }
        if let a = areas.first {
            let cx = Float(a.bounds.minX) + 140
            for (k, r) in [Float(30), 22, 15].enumerated() {
                balls.append(Ball(id: nextBallID, x: cx, y: Float(a.bounds.maxY) - 160 - Float(k) * 110, area: .pi * r * r))
                nextBallID += 1
            }
        }
        changed = true
    }

    // MARK: Кадр для отрисовки

    func buildFrame(for a: ScreenArea, dockLayer: Bool = false,
                    points: inout [PointVertex], tris: inout [TriVertex]) -> FrameRanges {
        points.removeAll(keepingCapacity: true)
        tris.removeAll(keepingCapacity: true)
        var r = FrameRanges()
        let x0 = Float(a.bounds.minX), x1 = Float(a.bounds.maxX)
        for s in a.surfaces where s.isDock == dockLayer { appendCap(s, max(s.a, x0), min(s.b, x1), &tris) }
        if !dockLayer { appendCap(a.groundSurface, x0, x1, &tris) }
        r.caps = tris.count

        let vis = a.bounds.insetBy(dx: -60, dy: -60)
        var shown: [Int] = []
        for (i, b) in balls.enumerated() where b.onDock == dockLayer && vis.contains(CGPoint(x: CGFloat(b.x), y: CGFloat(b.y))) {
            points.append(PointVertex(pos: b.pos, size: b.r * 2, alpha: 1, color: SIMD4(1, 1, 1, 1)))
            shown.append(i)
        }
        r.balls = points.count
        for i in shown { decorate(i, &points, &tris) }
        r.decor = tris.count
        if dockLayer { return r }

        for f in a.flakes {
            points.append(PointVertex(pos: SIMD2(f.x, f.y), size: f.size, alpha: f.alpha, color: SIMD4(1, 1, 1, 0)))
        }
        return r
    }

    /// Лицо на верхнем шаре снеговика, пуговицы на среднем.
    private func decorate(_ i: Int, _ points: inout [PointVertex], _ tris: inout [TriVertex]) {
        let b = balls[i]
        guard b.resting, !b.held else { return }
        let below = balls.contains { o in
            o.id != b.id && o.resting && abs(o.x - b.x) < o.r * 0.85 && o.y > b.y && abs((o.y - o.r * 0.9) - (b.y + b.r)) < 6
        }
        guard below else { return }
        let above = balls.contains { o in
            o.id != b.id && o.resting && abs(o.x - b.x) < b.r * 0.85 && o.y < b.y && abs((b.y - b.r * 0.9) - (o.y + o.r)) < 6
        }
        let r = b.r
        let coal = SIMD4<Float>(0.13, 0.13, 0.16, 2)
        if above {
            for k in -1...1 {
                points.append(PointVertex(pos: SIMD2(b.x, b.y + Float(k) * r * 0.32), size: max(2, r * 0.13), alpha: 1, color: coal))
            }
            return
        }
        points.append(PointVertex(pos: SIMD2(b.x - r * 0.32, b.y - r * 0.2), size: max(2, r * 0.17), alpha: 1, color: coal))
        points.append(PointVertex(pos: SIMD2(b.x + r * 0.32, b.y - r * 0.2), size: max(2, r * 0.17), alpha: 1, color: coal))
        for k in -2...2 {
            let t = Float(k) / 2
            points.append(PointVertex(pos: SIMD2(b.x + t * r * 0.36, b.y + r * 0.34 + (1 - t * t) * r * 0.08),
                                      size: max(1.5, r * 0.08), alpha: 1, color: coal))
        }
        let carrot = SIMD4<Float>(0.96, 0.52, 0.12, 1), tip = SIMD4<Float>(0.88, 0.40, 0.07, 1)
        tris.append(TriVertex(pos: SIMD2(b.x, b.y - r * 0.05), color: carrot))
        tris.append(TriVertex(pos: SIMD2(b.x, b.y + r * 0.11), color: carrot))
        tris.append(TriVertex(pos: SIMD2(b.x + r * 0.62, b.y + r * 0.07), color: tip))
    }

    private func appendCap(_ s: Surface, _ clipA: Float, _ clipB: Float, _ t: inout [TriVertex]) {
        guard clipB > clipA else { return }
        let map = s.map, c = map.cell, hs = map.h
        var i = max(0, Int(((clipA - s.originX) / c).rounded(.down)))
        let last = min(hs.count - 1, Int(((clipB - s.originX) / c).rounded(.up)))
        let top = SIMD4<Float>(0.985, 0.99, 1.0, 1)
        let low = SIMD4<Float>(0.83, 0.87, 0.94, 1)
        let rimIn = SIMD4<Float>(0.52, 0.58, 0.70, 0.32)
        let rimOut = SIMD4<Float>(0.52, 0.58, 0.70, 0)
        while i < last {
            if hs[i] < 0.12 && hs[i + 1] < 0.12 { i += 1; continue }
            var ha = map.smooth(i), hb = map.smooth(i + 1)
            var xa = s.originX + Float(i) * c, xb = xa + c
            if xa < clipA { ha += (hb - ha) * (clipA - xa) / c; xa = clipA }
            if xb > clipB { hb = ha + (hb - ha) * (clipB - xa) / max(xb - xa, 0.001); xb = clipB }
            if xb > xa {
                let ya = s.y - ha, yb = s.y - hb
                quad(&t, SIMD2(xa, ya), SIMD2(xb, yb), SIMD2(xb, s.y), SIMD2(xa, s.y), top, top, low, low)
                quad(&t, SIMD2(xa, ya - 1.5), SIMD2(xb, yb - 1.5), SIMD2(xb, yb), SIMD2(xa, ya), rimOut, rimOut, rimIn, rimIn)
            }
            i += 1
        }
    }

    @inline(__always)
    private func quad(_ t: inout [TriVertex], _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>,
                      _ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        t.append(TriVertex(pos: p0, color: c0)); t.append(TriVertex(pos: p1, color: c1)); t.append(TriVertex(pos: p2, color: c2))
        t.append(TriVertex(pos: p0, color: c0)); t.append(TriVertex(pos: p2, color: c2)); t.append(TriVertex(pos: p3, color: c3))
    }
}
