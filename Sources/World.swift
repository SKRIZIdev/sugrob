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
    var front = false          // слетела с Dock — рисуется слоем Dock, перед окнами
}

/// Снег на верхней кромке одного окна (или Dock).
final class Cap {
    var frame: CGRect
    let map: Heightmap
    var lastSeen: Double
    var lastSync: Double
    var visible = true
    var spill: Float = 0
    /// Прозрачные поля окна вокруг видимой плашки (у виджетов macOS 26 — 8 pt) и радиус её углов.
    let inset: CGFloat
    let corner: Float
    init(frame: CGRect, maxH: Float, now: Double, inset: CGFloat = 0, corner: Float = 0) {
        self.frame = frame
        self.inset = inset
        self.corner = corner
        map = Heightmap(width: Float(frame.width - 2 * inset), maxH: maxH, endRadius: corner)
        lastSeen = now
        lastSync = now
    }
    /// Видимая плашка: на её верх ложится снег.
    var platter: CGRect {
        CGRect(x: frame.minX + inset, y: frame.minY + inset,
               width: max(1, frame.width - 2 * inset), height: max(1, frame.height - 2 * inset))
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
    /// Радиус скругления концов (Dock). Снег у концов лежит не на прямой, а по дуге угла и
    /// толщину набирает по нормали — облегает угол, а не висит над ним.
    var corner: Float = 0
    /// Настоящие края плашки: видимый кусок кромки может быть обрезан окном спереди,
    /// но скругляются только настоящие углы.
    var endA: Float = 0, endB: Float = 0
    /// Уклон кромки dy/dx (скат крыши домика): опора y + slope·(x − originX), снег — по нормали.
    var slope: Float = 0

    /// Точка опоры под x и внешняя нормаль к ней (у прямой кромки — строго вверх).
    @inline(__always) func base(at x: Float) -> (y: Float, nx: Float, ny: Float) {
        if slope != 0 {
            let n = (1 + slope * slope).squareRoot()
            return (y + slope * (x - originX), slope / n, -1 / n)
        }
        guard corner > 0 else { return (y, 0, -1) }
        let r = corner
        let cx: Float
        if x - endA < r { cx = endA + r } else if endB - x < r { cx = endB - r } else { return (y, 0, -1) }
        let dx = max(-r, min(r, x - cx))
        let dy = (r * r - dx * dx).squareRoot()
        return (y + r - dy, dx / r, -dy / r)
    }
    @inline(__always) func top(at x: Float) -> Float {
        let g = base(at: x)
        return g.y + g.ny * map.height(at: x - originX)
    }
}

struct Ball {
    let id: Int
    var x: Float, y: Float
    var area: Float
    var vy: Float = 0
    var held = false, rolling = false, resting = false
    var window: CGWindowID? = nil
    var onDock = false          // стоит на Dock (сам или в стопке) — рисуется слоем Dock
    var vx: Float = 0
    var flying = false          // брошен — летит по дуге
    var dead = false            // разбился, удаляется в конце шага
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
    /// Пряничный домик с ёлкой в левом нижнем углу основного экрана.
    let scene = GingerbreadScene()
    private var sceneAnchor: SIMD2<Float> {
        guard let a = areas.first else { return .zero }
        return SIMD2(Float(a.bounds.minX) + 6 + 20 * scene.scale, Float(a.bounds.maxY))
    }

    /// Видимая «стеклянная» плашка Dock относительно рамки списка из Accessibility. Замер по
    /// скриншоту macOS 26 (10.11.2026): по горизонтали совпадает с рамкой, верх плашки на ~5 pt ниже
    /// верха рамки, радиус угла 28 pt. Без поправки снег висел над Dock в 5 pt от плашки.
    static var dockPlatterInsetX: CGFloat = 0
    static var dockPlatterTop: CGFloat = 5
    /// Радиус скругления углов плашки. Предел высоты снега у концов = cos угла наклона дуги.
    static var dockCorner: Float = 28
    static func platter(_ ax: CGRect) -> CGRect {
        CGRect(x: ax.minX + dockPlatterInsetX, y: ax.minY + dockPlatterTop,
               width: ax.width - 2 * dockPlatterInsetX, height: max(1, ax.height - dockPlatterTop))
    }
    private var dockVy: Float = 0
    private var dockGrow: Float = 1          // 0…1 — снег «распушается» на только что выехавшем Dock
    private var dockSquash: Float = 0        // пружина: <0 — сжат рывком вверх, >0 — подлетает
    private var dockSquashV: Float = 0
    private var dockLook: (scale: Float, alpha: Float) = (1, 1)
    private var dockSpill: Float = 0
    /// Снег с только что спрятавшегося Dock: тает на его слое, пока у кромки ложится настоящий сугроб.
    private var dockGhost: (map: Heightmap, originX: Float, y: Float, life: Float)?
    /// Сугроб, только что подхваченный выехавшим Dock: ~0.15 с тает у кромки на основном слое.
    /// Слои показываются независимо — без этой копии бывал кадр, где снега нет ни там, ни там.
    private var groundGhost: (map: Heightmap, originX: Float, y: Float, life: Float)?
    private let groundGhostLife: Float = 0.15
    /// Dock двигается или с него ещё падает/тает снег — для замера плавности.
    private(set) var dockBusy = false
    private let ghostLife: Float = 0.9
    /// Снег, сорвавшийся с уходящего вниз Dock: миг держится, падает пластом, у кромки разбивается.
    private var dockSlab: (map: Heightmap, originX: Float, y: Float, vy: Float, age: Float)?
    private let slabGravity: Float = 2200

    /// Dock на экране (выехал или едет) — его надо опрашивать каждый кадр.
    var dockShown: Bool { dock?.visible == true }
    /// Какой высоты нужна полоса слоя Dock на этом экране: Dock со снегом, а если на нём стоит
    /// снеговик — до его макушки (с шагом 60 pt, чтобы окно не дёргалось на каждом кадре).
    func dockLayerHeight(for a: ScreenArea) -> CGFloat {
        var top = Float(a.bounds.maxY) - 170
        for b in balls where b.onDock && b.x >= Float(a.bounds.minX) && b.x < Float(a.bounds.maxX) {
            top = min(top, b.y - b.r - 16)
        }
        let need = CGFloat(Float(a.bounds.maxY) - top)
        return need <= 170 ? 170 : (need / 60).rounded(.up) * 60
    }

    /// Тает ли сейчас копия снега спрятавшегося Dock (для проверок).
    var dockGhostAlive: Bool { dockGhost != nil }
    /// Падает ли сейчас пласт снега, сорвавшийся с Dock (для проверок).
    var dockSlabFalling: Bool { dockSlab != nil }
    var dockSlabDebug: String { dockSlab.map { "y=\(Int($0.y)) vy=\(Int($0.vy)) age=\(String(format: "%.2f", $0.age))" } ?? "-" }
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
                    if abs(old.width - w.frame.width) > 0.5 { cap.map.resize(width: Float(w.frame.width - 2 * cap.inset)) }
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
                // Виджет: окно на 8 pt больше видимой плашки, углы плашки — 28 pt (замер 10.11).
                // Обычное окно стоит перед слоем снега, и снег на его углу с запасом прячется за ним.
                caps[w.id] = w.kind == .widget
                    ? Cap(frame: w.frame, maxH: 12, now: now, inset: 8, corner: 28)
                    : Cap(frame: w.frame, maxH: 16, now: now, corner: 12)
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
            dock = Cap(frame: SnowWorld.platter(f), maxH: 12, now: now, corner: SnowWorld.dockCorner)
            dock?.visible = false
            dockArea = a
            dockTop = min(Float(SnowWorld.platter(f).minY), Float(a.bounds.maxY))
            dockRaised = false
        }
    }

    /// Dock со скрытием выезжает из-под нижней кромки: на старте он подхватывает сугроб, лежавший
    /// над ним, снег «распушается» и вверх взлетает снежная пыль; на рывке вверх сугроб сжимается,
    /// на остановке подпрыгивает (пружина), с краёв крошится. Прячась — везёт снег вниз, у кромки
    /// кладёт его обратно сугробом, а на слое Dock его копия плавно тает.
    private func stepDock(_ dt: Float) {
        dockBusy = dockSlab != nil || dockGhost != nil || groundGhost != nil
        if var g = dockGhost {
            g.life += dt
            dockGhost = g.life < ghostLife ? g : nil
            changed = true
        }
        if var g = groundGhost {
            g.life += dt
            groundGhost = g.life < groundGhostLife ? g : nil
            changed = true
        }
        guard let d = dock, let a = dockArea else { return }
        guard let raw = dockTarget else {
            if d.visible { d.visible = false; rebuildSurfaces(); changed = true }
            stepSlab(dt)
            return
        }
        let f = SnowWorld.platter(raw)
        let bottom = Float(a.bounds.maxY)
        // Accessibility отдаёт каждый шаг анимации Dock (~раз в 10 мс) — идём за ним без сглаживания.
        let old = dockTop
        dockTop = min(Float(f.minY), bottom)
        let vy = (dockTop - old) / max(dt, 0.001)
        let acc = max(-20000, min(20000, (vy - dockVy) / max(dt, 0.001)))
        dockVy = vy
        if abs(d.frame.width - f.width) > 0.5 { d.map.resize(width: Float(f.width)) }

        let shown = dockTop < bottom - 0.5
        // Dock пошёл вниз — снег с него срывается пластом и дальше падает сам.
        if dockRaised, shown, vy > 40, dockSlab == nil, d.map.total > 1 {
            // Трение тянет снег за полкой: он стартует с частью её скорости, но отстаёт.
            dockSlab = (d.map.copy(), Float(d.frame.minX), old, max(0, vy * 0.45), 0)
            d.map.clear()
        }
        if shown && !dockRaised {
            let ghost = Heightmap(width: Float(f.width), maxH: 100)
            ghost.absorb(a.ground.copy(), offset: Float(f.minX - a.bounds.minX))
            if ghost.total > 1 { groundGhost = (ghost, Float(f.minX), bottom, 0) }
            let (l, r) = d.map.absorb(a.ground, offset: Float(f.minX - a.bounds.minX))
            dockRaised = true
            dockGrow = 0
            dockSquash = 0
            dockSquashV = 0
            crumble(x: Float(f.minX), y: dockTop, amount: l, dir: -1)
            crumble(x: Float(f.maxX), y: dockTop, amount: r, dir: 1)
            puff(d.map, originX: Float(f.minX), top: dockTop)
        } else if !shown && dockRaised {
            if d.map.total > 1 {
                dockGhost = (d.map.copy(), Float(f.minX), bottom, 0)
                a.ground.absorb(d.map, offset: Float(a.bounds.minX - f.minX))
            }
            d.map.clear()
            dockRaised = false
            // Снеговики доехали до кромки и стоят уже на земле — рисуются снова за окнами.
            if dockSlab == nil { for i in balls.indices where balls[i].onDock { balls[i].onDock = false } }
        }

        // Пружина «снег на подвижной полке».
        dockSquashV += (-360 * dockSquash - 13 * dockSquashV + acc * 0.011) * dt
        dockSquash = min(0.35, max(-0.4, dockSquash + dockSquashV * dt))
        if dockGrow < 1 { dockGrow = min(1, dockGrow + dt / 0.55) }
        let t = dockGrow - 1
        let back = 1 + 2.70158 * t * t * t + 1.70158 * t * t          // easeOutBack: 0 → 1 с перелётом
        dockLook = ((0.5 + 0.5 * back) * (1 + dockSquash), min(1, 0.35 + dockGrow * 1.6))
        if dockGrow < 1 || abs(dockSquash) > 0.002 || abs(dockSquashV) > 0.02 { changed = true }

        stepSlab(dt)
        let frame = CGRect(x: f.minX, y: CGFloat(dockTop), width: f.width, height: f.height)
        guard frame != d.frame || d.visible != shown else { return }
        dockBusy = true
        // Снеговики на Dock едут вместе с ним (пока снег не сорвался — тогда падают с пластом).
        let dy = dockTop - old
        if dy != 0 && dockSlab == nil {
            for i in balls.indices where balls[i].onDock && balls[i].resting && !balls[i].held { balls[i].y += dy }
        }
        d.frame = frame
        d.visible = shown
        // Немного снега крошится на рывках — несколько крошек, а не сплошная пыль.
        let rate = max(0, abs(vy) - 200) / 700
        if shown, rate > 0 { shake(d, vx: 0, vy: vy, fraction: min(0.06, 1 - exp(-rate * dt)), front: true) }
        rebuildSurfaces()
        if shown { liftBalls() }
        changed = true
    }

    /// Пласт снега с ушедшего Dock: отстаёт от полки и падает с ускорением, крошась; у кромки
    /// ложится сугробом, взбивает пыль, а на слое Dock его копия ещё 0.9 с тает. Если Dock успел
    /// снова выехать — пласт ложится обратно на него.
    private func stepSlab(_ dt: Float) {
        guard var s = dockSlab, let a = dockArea else { return }
        changed = true
        s.age += dt
        s.vy += slabGravity * dt
        var dy = s.vy * dt
        let bottom = Float(a.bounds.maxY)
        let onDock = dock?.visible == true && dockTop < s.y + dy
        let floor = onDock ? dockTop : bottom
        if s.y + dy >= floor {
            dy = floor - s.y
            if onDock, let d = dock {
                d.map.absorb(s.map, offset: Float(d.frame.minX) - s.originX)
                dockRaised = true
            } else {
                a.ground.absorb(s.map.copy(), offset: Float(a.bounds.minX) - s.originX)
                dockGhost = (s.map, s.originX, bottom, 0)
                puff(s.map, originX: s.originX, top: bottom)
                for i in balls.indices where balls[i].onDock { balls[i].onDock = false }
            }
            dockSlab = nil
        } else {
            s.y += dy
            // Крошится на лету.
            if rng.unit() < dt * 40 {
                let lx = rng.unit() * s.map.width
                let h = s.map.height(at: lx)
                if h > 0.8 {
                    emitOne(x: s.originX + lx, y: s.y - h, vx: rng.signed() * 30, vy: s.vy * 0.6 - 20,
                            stick: 0.1, front: true)
                }
            }
            dockSlab = s
        }
        if dy != 0 {
            for i in balls.indices where balls[i].onDock && !balls[i].held { balls[i].y += dy }
        }
    }

    /// Сменить размер домика (снег с крыши осыпается).
    func setHouseScale(_ k: Float) {
        guard abs(k - scene.scale) > 0.001 else { return }
        dropSceneSnow()
        scene.setScale(k)
        rebuildSurfaces()
        changed = true
    }

    /// Домик убирают — снег с крыши и трубы осыпается.
    func dropSceneSnow() {
        for (map, x0, y0, k, _) in scene.roofParts(anchor: sceneAnchor) {
            var x: Float = 0
            while x < map.width {
                let h = map.height(at: x)
                if h > 0.6 { emitOne(x: x0 + x, y: y0 + k * x - h, vx: rng.signed() * 25, vy: rng.range(-40...0), stick: 0) }
                x += 5
            }
        }
        scene.clearSnow()
    }

    /// Крошки с конца Dock: то, что не удержалось на скруглённом краю.
    private func crumble(x: Float, y: Float, amount: Float, dir: Float) {
        let n = min(16, Int(amount / 6))
        for _ in 0..<n {
            emitOne(x: x - dir * rng.unit() * 10, y: y - rng.unit() * 6, vx: dir * rng.range(25...80),
                    vy: rng.range(-50...10), stick: 0.1, front: true)
        }
    }

    /// Снежная пыль, взлетающая с Dock, когда он подхватывает сугроб.
    private func puff(_ map: Heightmap, originX: Float, top: Float) {
        guard map.total > 20 else { return }
        var made = 0, tries = 0
        while made < 18 && tries < 120 {
            tries += 1
            let lx = rng.unit() * map.width
            let h = map.height(at: lx)
            guard h > 1 else { continue }
            emitOne(x: originX + lx, y: top - h, vx: rng.signed() * 35, vy: rng.range(-160 ... -60),
                    stick: 0, front: true, size: 1.2...2.6)
            made += 1
        }
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
    func rebuildSurfaces() {
        var list: [Surface] = []
        var wins: [(CGWindowID, CGRect)] = []
        for id in order { if let c = caps[id], c.visible { wins.append((id, c.platter)) } }
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
                                originX: Float(df.minX), map: d.map, window: nil, isDock: true,
                                corner: SnowWorld.dockCorner, endA: Float(df.minX), endB: Float(df.maxX)))
        }
        // Слой снега лежит под всеми окнами: шапку над кромкой прячет любое окно, виджет или Dock,
        // занявшие полосу над ней, — снег виден только на открытом рабочем столе.
        if settings.accumulate {
            let dockRects = dockFrame.map { [$0] } ?? []
            for (id, f) in wins {
                guard let cap = caps[id] else { continue }
                for s in segments(f, hiddenBy: dockRects + wins.filter { $0.0 != id }.map { $0.1 }) {
                    list.append(Surface(a: Float(s.0), b: Float(s.1), y: Float(f.minY),
                                        originX: Float(f.minX), map: cap.map, window: id,
                                        corner: cap.corner, endA: Float(f.minX), endB: Float(f.maxX)))
                }
            }
        }
        list += scene.surfaces(anchor: sceneAnchor)
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
        let (sceneActive, sceneSolid) = scene.step(dt, wind: wind)
        if sceneSolid {
            if !scene.solid { dropSceneSnow() }
            rebuildSurfaces()
        }
        if sceneActive { changed = true }
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
                let pl = cap.platter
                let x = Float(left ? pl.minX : pl.maxX) + (left ? -2 : 2)
                emit(x: x, y: Float(pl.minY) + cap.corner * 0.6, vx: left ? -14 : 14, vy: 12, area: cap.spill, spread: 1.5)
                cap.spill = 0
            }
        }
        if let d = dock, d.map.dirty {
            let (l, r) = d.map.relax()
            changed = true
            if d.visible {
                dockSpill += l + r
                if dockSpill > 6 {
                    let left = l >= r
                    crumble(x: Float(left ? d.frame.minX : d.frame.maxX), y: Float(d.frame.minY), amount: dockSpill, dir: left ? -1 : 1)
                    dockSpill = 0
                }
            }
        }
        for a in areas where a.ground.dirty { a.ground.relax(edges: false); changed = true }
        for m in [scene.roofLeft, scene.roofRight, scene.chimneyTop] where m.dirty { m.relax(edges: false); changed = true }
    }

    // MARK: Сброс снега

    /// Окно дёрнули — часть снега слетает, унося скорость окна.
    private func shake(_ cap: Cap, vx: Float, vy: Float, fraction frac: Float, front: Bool = false) {
        let map = cap.map
        let total = map.total
        guard total > 4, frac > 0.001 else { return }
        let removed = total * frac
        // Слетевший снег — снежинки; мелочь не плодим, она просто исчезает.
        let count = min(40, Int(removed / 7))
        guard count > 0 else { map.scale(1 - frac); changed = true; return }
        let step = max(1, map.h.count / count)
        let x0 = Float(cap.platter.minX), y0 = Float(cap.platter.minY)
        var i = Int(rng.unit() * Float(step))
        while i < map.h.count {
            if map.h[i] > 0.3 {
                emitOne(x: x0 + Float(i) * map.cell, y: y0 - map.h[i] * rng.unit(),
                        vx: vx * 0.45 + rng.signed() * 30, vy: min(vy * 0.45, 60) - 25 + rng.signed() * 20, front: front)
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
                emit(x: mouse.x, y: top, vx: mouseVel.x * 0.55, vy: min(mouseVel.y * 0.4, 0) - 35, area: taken,
                     spread: radius, front: s.isDock)
            }
        }
        guard speed > 120 else { return }
        var i = balls.count - 1
        while i >= 0 {
            let b = balls[i]
            if simd_distance(b.pos, mouse) < b.r {
                emit(x: b.x, y: b.y, vx: mouseVel.x * 0.5, vy: -40, area: min(b.area * 0.5, 300), spread: b.r, front: b.onDock)
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
                    emitOne(x: x, y: s.y - h * rng.unit(), vx: rng.signed() * 20, vy: rng.range(-30...10), stick: 0, front: s.isDock)
                    budget -= 1
                }
                x += 7
            }
        }
        for b in balls where budget > 0 {
            emit(x: b.x, y: b.y, vx: 0, vy: -20, area: min(b.area * 0.3, 160), spread: b.r, stick: 0, front: b.onDock)
            budget -= 10
        }
        for c in caps.values { c.map.clear() }
        scene.clearSnow()
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

    private func emitOne(x: Float, y: Float, vx: Float, vy: Float, stick: Float = 0.18,
                         front: Bool = false, size: ClosedRange<Float> = 2.2...4.2) {
        guard let a = area(containing: x, y) else { return }
        let fall = rng.range(70...120)
        a.flakes.append(Flake(x: x, y: y, vx: vx, vy: vy, fall: fall, size: rng.range(size),
                              phase: rng.unit() * 6.283, swayFreq: rng.range(0.8...1.6), swayAmp: rng.range(3...9),
                              resp: 0.8, stick: stick, alpha: rng.range(0.75...0.95), front: front))
    }

    private func emit(x: Float, y: Float, vx: Float, vy: Float, area amount: Float, spread: Float = 6,
                      stick: Float = 0.18, front: Bool = false) {
        let n = min(24, max(1, Int(amount / 7)))
        for _ in 0..<n {
            emitOne(x: x + rng.signed() * spread, y: y - rng.unit() * 3,
                    vx: vx + rng.signed() * 25, vy: vy + rng.signed() * 20, stick: stick, front: front)
        }
    }

    // MARK: Снежки и снеговики

    private func stepBalls(_ dt: Float) -> Bool {
        guard !balls.isEmpty else { return false }
        var active = false
        let floor = areas.map { Float($0.bounds.maxY) }.max() ?? 3000
        for i in balls.indices {
            if balls[i].held || balls[i].dead { active = true; continue }
            if balls[i].flying { active = true; fly(i, dt); continue }
            // Снеговик на сорвавшемся с Dock пласте падает вместе с ним (двигает stepSlab).
            if dockSlab != nil && balls[i].onDock { active = true; continue }
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
        balls.removeAll { $0.dead || (!$0.held && $0.y > floor + 300) }
        if balls.count != before { changed = true }
        return active
    }

    /// Брошенный снежок: дуга под тяжестью, подшаги не длиннее 10 pt (чтобы не проскочить тонкую
    /// кромку). Медленно сел — лежит; на скорости — разбивается брызгами и налипает снегом на место
    /// удара. Попал в ком — сбивает его; в край экрана — разбивается о него.
    private func fly(_ i: Int, _ dt: Float) {
        let speed0 = simd_length(SIMD2(balls[i].vx, balls[i].vy))
        let steps = max(1, min(12, Int((speed0 * dt / 10).rounded(.up))))
        let h = dt / Float(steps)
        let minX = areas.map { Float($0.bounds.minX) }.min() ?? 0
        let maxX = areas.map { Float($0.bounds.maxX) }.max() ?? 3000
        for _ in 0..<steps {
            let (support, win, dockSupport) = supportY(i)
            balls[i].vy += 1500 * h
            balls[i].vx *= 1 - 0.25 * h
            balls[i].x += balls[i].vx * h
            balls[i].y += balls[i].vy * h
            let b = balls[i], r = b.r
            let speed = simd_length(SIMD2(b.vx, b.vy))

            if speed > 380 {
                for j in balls.indices where j != i && !balls[j].dead && !balls[j].held && !balls[j].flying {
                    let o = balls[j]
                    let d = simd_distance(b.pos, o.pos)
                    guard d < r + o.r * 0.9 else { continue }
                    // Сбили ком: лёгкий улетает почти со скоростью снежка, тяжёлый едва сдвигается.
                    let k = min(1, (r * r) / (o.r * o.r)) * 0.7
                    balls[j].flying = true
                    balls[j].resting = false
                    balls[j].window = nil
                    balls[j].onDock = false
                    balls[j].vx = b.vx * k
                    balls[j].vy = min(b.vy * k, 0) - 140 * k
                    let n = simd_normalize(b.pos - o.pos)
                    splat(i, nx: n.x, ny: n.y)
                    return
                }
            }
            if b.x - r < minX || b.x + r > maxX {
                balls[i].x = min(max(b.x, minX + r), maxX - r)
                splat(i, nx: b.x - r < minX ? 1 : -1, ny: 0)
                return
            }
            if b.vy > 0 && b.y + r >= support {
                balls[i].y = support - r
                if b.vy < 320 {                      // мягко сел
                    balls[i].flying = false
                    balls[i].vx = 0
                    balls[i].vy = 0
                    balls[i].resting = true
                    balls[i].window = win
                    balls[i].onDock = dockSupport
                    if let w = win, let cap = caps[w] {
                        balls[i].off = SIMD2(balls[i].x - Float(cap.frame.minX), balls[i].y - Float(cap.frame.minY))
                    }
                } else {
                    stickSnow(x: b.x, y: support, area: b.area * 0.45, spread: r)
                    splat(i, nx: 0, ny: -1)
                }
                return
            }
        }
    }

    /// Снежок разбился: брызги разлетаются от места удара, сам ком исчезает.
    private func splat(_ i: Int, nx: Float, ny: Float) {
        let b = balls[i]
        let n = min(40, max(8, Int(b.area / 6)))
        for _ in 0..<n {
            emitOne(x: b.x - nx * b.r * 0.5 + rng.signed() * b.r * 0.5,
                    y: b.y - ny * b.r * 0.5 + rng.signed() * b.r * 0.4,
                    vx: b.vx * 0.2 + nx * rng.range(40...200) + rng.signed() * 90,
                    vy: b.vy * 0.1 + ny * rng.range(40...180) - rng.range(30...140),
                    stick: 0.35, front: b.onDock, size: 2...4.6)
        }
        balls[i].dead = true
        changed = true
    }

    /// Налипший от удара снег: кладётся на ту кромку (окна, Dock или сугроб), что под точкой.
    private func stickSnow(x: Float, y: Float, area: Float, spread: Float) {
        var all = surfaces
        for a in areas { all.append(a.groundSurface) }
        guard let s = all.first(where: { x >= $0.a && x <= $0.b && abs($0.top(at: x) - y) < 10 }) else { return }
        let parts = 5
        for k in 0..<parts {
            let px = x + (Float(k) / Float(parts - 1) - 0.5) * spread * 1.4
            s.map.deposit(at: px - s.originX, area: area / Float(parts))
        }
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
            var sy = g.top(at: b.x) + min(r * 0.25, a.ground.height(at: b.x - g.originX) * 0.6)
            // Сугроб вырос прямо под комом (например, на него рухнул снег с Dock) — ком не
            // проваливается сквозь землю, а остаётся стоять, присыпанный.
            if sy < bottom - 4 && bottom <= Float(a.bounds.maxY) + 2 { sy = bottom }
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
            balls[i].vx = 0
            balls[i].vy = 0
            // Отпустил на замахе — бросок: ком летит со скоростью руки (не быстрее 2600 pt/с).
            let speed = simd_length(mouseVel)
            if speed > 250 {
                let k = min(1, 2600 / speed) * 0.9
                balls[i].vx = mouseVel.x * k
                balls[i].vy = mouseVel.y * k
                balls[i].flying = true
                balls[i].resting = false
                balls[i].window = nil
                balls[i].onDock = false
            }
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
        // Домик рисуется первым: сугроб у кромки прикрывает его основание, снег на крыше — поверх.
        if !dockLayer, a === areas.first, scene.visible { scene.draw(anchor: sceneAnchor, tris: &tris, points: &points) }
        for s in a.surfaces where s.isDock == dockLayer {
            appendCap(s, max(s.a, x0), min(s.b, x1), &tris,
                      scale: s.isDock ? dockLook.scale : 1, alpha: s.isDock ? dockLook.alpha : 1)
        }
        if !dockLayer { appendCap(a.groundSurface, x0, x1, &tris) }
        if !dockLayer, let g = groundGhost, dockArea === a {
            let k = g.life / groundGhostLife
            let ghost = Surface(a: g.originX, b: g.originX + g.map.width, y: g.y, originX: g.originX, map: g.map, window: nil)
            appendCap(ghost, max(ghost.a, x0), min(ghost.b, x1), &tris, alpha: 1 - k)
        }
        if dockLayer, let sl = dockSlab, dockArea === a {
            let slab = Surface(a: sl.originX, b: sl.originX + sl.map.width, y: sl.y, originX: sl.originX, map: sl.map, window: nil)
            appendCap(slab, max(slab.a, x0), min(slab.b, x1), &tris)
        }
        if dockLayer, let g = dockGhost, dockArea === a {
            let k = g.life / ghostLife
            let ghost = Surface(a: g.originX, b: g.originX + g.map.width, y: g.y, originX: g.originX, map: g.map, window: nil)
            // Тает медленно в начале и быстрее к концу, заметно оседая.
            appendCap(ghost, max(ghost.a, x0), min(ghost.b, x1), &tris, scale: 1 - 0.5 * k, alpha: 1 - k * k)
        }
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
        for f in a.flakes where f.front == dockLayer {
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

    private func appendCap(_ s: Surface, _ clipA: Float, _ clipB: Float, _ t: inout [TriVertex],
                           scale: Float = 1, alpha: Float = 1) {
        guard clipB > clipA else { return }
        let map = s.map, c = map.cell, hs = map.h
        var i = max(0, Int(((clipA - s.originX) / c).rounded(.down)))
        let last = min(hs.count - 1, Int(((clipB - s.originX) / c).rounded(.up)))
        let top = SIMD4<Float>(0.985, 0.99, 1.0, alpha)
        let low = SIMD4<Float>(0.83, 0.87, 0.94, alpha)
        let rimIn = SIMD4<Float>(0.52, 0.58, 0.70, 0.32 * alpha)
        let rimOut = SIMD4<Float>(0.52, 0.58, 0.70, 0)
        while i < last {
            if hs[i] < 0.12 && hs[i + 1] < 0.12 { i += 1; continue }
            var ha = map.smooth(i) * scale, hb = map.smooth(i + 1) * scale
            var xa = s.originX + Float(i) * c, xb = xa + c
            if xa < clipA { ha += (hb - ha) * (clipA - xa) / c; xa = clipA }
            if xb > clipB { hb = ha + (hb - ha) * (clipB - xa) / max(xb - xa, 0.001); xb = clipB }
            if xb > xa {
                // Снег откладывается от опоры по нормали: на прямой кромке — вверх, на дуге
                // скруглённого угла — наружу от дуги, и слой облегает угол.
                let ga = s.base(at: xa), gb = s.base(at: xb)
                let na = SIMD2(ga.nx, ga.ny), nb = SIMD2(gb.nx, gb.ny)
                let ia = SIMD2(xa, ga.y), ib = SIMD2(xb, gb.y)
                let oa = ia + na * ha, ob = ib + nb * hb
                quad(&t, oa, ob, ib, ia, top, top, low, low)
                quad(&t, oa + na * 1.5, ob + nb * 1.5, ob, oa, rimOut, rimOut, rimIn, rimIn)
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
