// Проверка без экрана: симуляция на выдуманных окнах + отрисовка теми же шейдерами в PNG.
//   ./tests/snapshot.sh <папка для png>
import AppKit
import Metal

let W: CGFloat = 1470, H: CGFloat = 956, S: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["SNAP_SCALE"] ?? "2") ?? 2)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failures += 1 }
}

Settings.shared.intensity = .steady
Settings.shared.wind = .calm
Settings.shared.paused = false
Settings.shared.accumulate = true

let world = SnowWorld()
world.depositBoost = 6
world.setScreens([(1, CGRect(x: 0, y: 0, width: W, height: H))])

// Спереди назад: окно 12 стоит за окном 11, и у него видна только правая часть кромки.
var wins = [
    TrackedWindow(id: 10, frame: CGRect(x: 180, y: 360, width: 560, height: 380), kind: .normal),
    TrackedWindow(id: 11, frame: CGRect(x: 520, y: 210, width: 640, height: 470), kind: .normal),
    TrackedWindow(id: 12, frame: CGRect(x: 900, y: 260, width: 430, height: 300), kind: .normal),
    TrackedWindow(id: 13, frame: CGRect(x: 60, y: 110, width: 170, height: 170), kind: .widget),
]
var now = 0.0
func run(_ seconds: Double) {
    for _ in 0..<Int(seconds * 60) {
        now += 1.0 / 60
        world.syncWindows(wins, now: now)
        world.step(dt: 1.0 / 60)
    }
}

print("Снегопад 90 с:")
run(90)
let segs12 = world.surfaces.filter { $0.window == 12 }
check(segs12.count == 1 && abs(segs12[0].a - 1160) < 0.5 && abs(segs12[0].b - 1330) < 0.5,
      "кромка окна 12 видна только справа от окна 11: \(segs12.map { "\(Int($0.a))…\(Int($0.b))" })")
func capHeight(_ id: CGWindowID, _ x: Float) -> Float {
    guard let s = world.surfaces.first(where: { $0.window == id && x >= $0.a && x <= $0.b }) else { return -1 }
    return s.map.height(at: x - s.originX)
}
let segs10 = world.surfaces.filter { $0.window == 10 }.map { "\(Int($0.a))…\(Int($0.b))" }
check(segs10 == ["180…520"], "над кромкой окна 10 справа висит окно 11 — снег только слева: \(segs10)")
check(capHeight(11, 840) > 3, "на окне 11 лежит снег: \(capHeight(11, 840)) pt")
check(capHeight(13, 145) > 1, "на виджете 13 лежит снег: \(capHeight(13, 145)) pt")
if let w = world.surfaces.first(where: { $0.window == 13 }) {
    check(w.y == 118 && w.endA == 68 && w.endB == 222 && w.corner == 28,
          "снег на виджете лежит на плашке (окно минус поля 8 pt), углы 28 pt: верх \(w.y), края \(w.endA)…\(w.endB)")
}
let groundMid = world.areas[0].ground.height(at: 735)
check(groundMid > 2, "сугроб у нижнего края: \(groundMid) pt")
let flakes = world.areas[0].flakes.count
check(flakes > 300 && flakes < 1100, "снежинок в воздухе: \(flakes)")

// Снеговик: катаем три кома по сугробу и ставим друг на друга — теми же вызовами, что у мыши.
func roll(from x0: Float, to x1: Float) {
    let g = world.areas[0].groundSurface
    world.sculptDown(SIMD2(x0, g.top(at: x0) - 2))
    let n = 60
    for k in 1...n {
        let x = x0 + (x1 - x0) * Float(k) / Float(n)
        world.sculptDrag(SIMD2(x, g.top(at: x) - 2))
    }
}
/// Поднять ком, который сейчас в руке, и отпустить над точкой x — как это делает человек мышью.
func lift(to x: Float, y: Float) {
    guard let b = world.balls.last else { return }
    let start = SIMD2(b.x, b.y)
    for k in 1...30 {
        let t = Float(k) / 30
        world.sculptDrag(SIMD2(start.x + (x - start.x) * t, start.y + (y - start.y) * t))
    }
    world.sculptUp()
    run(1.2)
}
roll(from: 1400, to: 1180); world.sculptUp(); run(1)
roll(from: 980, to: 1110); lift(to: 1180, y: 600)
roll(from: 1000, to: 1070); lift(to: 1180, y: 480)
let stack = world.balls.sorted { $0.y > $1.y }
check(stack.count == 3, "слеплено комов: \(stack.count), радиусы \(stack.map { Int($0.r) })")
if stack.count == 3 {
    check(stack.allSatisfy { $0.resting } && stack[0].r > stack[1].r && stack[1].r > stack[2].r
          && abs(stack[2].x - stack[0].x) < stack[0].r * 0.85, "комья стоят друг на друге, снизу вверх меньше")
}

// --- отрисовка в текстуру ---
let gpu = GPU.shared
let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(W * S), height: Int(H * S), mipmapped: false)
td.usage = [.renderTarget]
td.storageMode = .shared
let tex = gpu.device.makeTexture(descriptor: td)!

func rect(_ t: inout [TriVertex], _ r: CGRect, _ top: SIMD4<Float>, _ bottom: SIMD4<Float>) {
    let a = SIMD2(Float(r.minX), Float(r.minY)), b = SIMD2(Float(r.maxX), Float(r.minY))
    let c = SIMD2(Float(r.maxX), Float(r.maxY)), d = SIMD2(Float(r.minX), Float(r.maxY))
    t += [TriVertex(pos: a, color: top), TriVertex(pos: b, color: top), TriVertex(pos: c, color: bottom),
          TriVertex(pos: a, color: top), TriVertex(pos: c, color: bottom), TriVertex(pos: d, color: bottom)]
}

func render(_ name: String, lightWindows: Bool) {
    var bg: [TriVertex] = [], front: [TriVertex] = []
    rect(&bg, CGRect(x: 0, y: 0, width: W, height: H), SIMD4(0.10, 0.16, 0.27, 1), SIMD4(0.20, 0.30, 0.38, 1))
    for w in wins.reversed() {
        if w.kind == .widget {
            // Виджет: прозрачные поля 8 pt и плашка со скруглёнными углами 28 pt.
            let p = w.frame.insetBy(dx: 8, dy: 8), r: CGFloat = 28
            let c = SIMD4<Float>(0.22, 0.24, 0.28, 0.92)
            rect(&front, p.insetBy(dx: r, dy: 0), c, c)
            rect(&front, CGRect(x: p.minX, y: p.minY + r, width: r, height: p.height - 2 * r), c, c)
            rect(&front, CGRect(x: p.maxX - r, y: p.minY + r, width: r, height: p.height - 2 * r), c, c)
            for (cx, cy) in [(p.minX + r, p.minY + r), (p.maxX - r, p.minY + r), (p.minX + r, p.maxY - r), (p.maxX - r, p.maxY - r)] {
                let o = SIMD2(Float(cx), Float(cy))
                let sx: Float = cx < p.midX ? -1 : 1, sy: Float = cy < p.midY ? -1 : 1
                for k in 0..<12 {
                    let a0 = Float(k) / 12 * .pi / 2, a1 = Float(k + 1) / 12 * .pi / 2
                    front += [TriVertex(pos: o, color: c),
                              TriVertex(pos: o + SIMD2(sx * cos(a0), sy * sin(a0)) * Float(r), color: c),
                              TriVertex(pos: o + SIMD2(sx * cos(a1), sy * sin(a1)) * Float(r), color: c)]
                }
            }
            continue
        }
        let body: SIMD4<Float> = lightWindows ? SIMD4(1, 1, 1, 1) : SIMD4(0.16, 0.17, 0.19, 1)
        let bar: SIMD4<Float> = lightWindows ? SIMD4(0.93, 0.93, 0.94, 1) : SIMD4(0.22, 0.23, 0.25, 1)
        rect(&front, w.frame, body, body)          // снег идёт за окнами
        rect(&front, CGRect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: 28), bar, bar)
    }
    var points: [PointVertex] = [], tris: [TriVertex] = []
    let r = world.buildFrame(for: world.areas[0], points: &points, tris: &tris)
    let all = bg + tris + front
    let tb = gpu.device.makeBuffer(bytes: all, length: all.count * MemoryLayout<TriVertex>.stride)!
    let pb = gpu.device.makeBuffer(bytes: points.isEmpty ? [PointVertex(pos: .zero, size: 0, alpha: 0, color: .zero)] : points,
                                   length: max(points.count, 1) * MemoryLayout<PointVertex>.stride)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = tex
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    let cmd = gpu.queue.makeCommandBuffer()!
    let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
    var u = Uniforms(origin: .zero, size: SIMD2(Float(W), Float(H)), scale: Float(S))
    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    let off = bg.count
    enc.setRenderPipelineState(gpu.triPipeline); enc.setVertexBuffer(tb, offset: 0, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: off + r.caps)
    if r.balls > 0 {
        enc.setRenderPipelineState(gpu.pointPipeline); enc.setVertexBuffer(pb, offset: 0, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: r.balls)
    }
    if r.decor > r.caps {
        enc.setRenderPipelineState(gpu.triPipeline); enc.setVertexBuffer(tb, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: off + r.caps, vertexCount: r.decor - r.caps)
    }
    if points.count > r.balls {
        enc.setRenderPipelineState(gpu.pointPipeline); enc.setVertexBuffer(pb, offset: 0, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: r.balls, vertexCount: points.count - r.balls)
    }
    if !front.isEmpty {
        enc.setRenderPipelineState(gpu.triPipeline); enc.setVertexBuffer(tb, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: off + tris.count, vertexCount: front.count)
    }
    // Dock и снег на нём — над окнами, как в приложении.
    // Слой Dock рисуется всегда: на нём и падающий пласт, и тающая копия, и снеговик на пласте.
    if let d = world.dockState {
        var dockTris: [TriVertex] = []
        // Плашка Dock со скруглёнными углами, как в macOS 26 (если Dock на экране).
        let bar = SIMD4<Float>(0.55, 0.58, 0.64, world.dockShown ? 0.55 : 0)
        let pf = CGRect(x: d.frame.minX, y: d.frame.minY, width: d.frame.width, height: 76)
        let rr = CGFloat(SnowWorld.dockCorner)
        rect(&dockTris, pf.insetBy(dx: rr, dy: 0), bar, bar)
        rect(&dockTris, CGRect(x: pf.minX, y: pf.minY + rr, width: rr, height: pf.height - 2 * rr), bar, bar)
        rect(&dockTris, CGRect(x: pf.maxX - rr, y: pf.minY + rr, width: rr, height: pf.height - 2 * rr), bar, bar)
        for (cx, cy) in [(pf.minX + rr, pf.minY + rr), (pf.maxX - rr, pf.minY + rr), (pf.minX + rr, pf.maxY - rr), (pf.maxX - rr, pf.maxY - rr)] {
            let c = SIMD2(Float(cx), Float(cy))
            let sx: Float = cx < pf.midX ? -1 : 1, sy: Float = cy < pf.midY ? -1 : 1
            for k in 0..<12 {
                let a0 = Float(k) / 12 * .pi / 2, a1 = Float(k + 1) / 12 * .pi / 2
                dockTris += [TriVertex(pos: c, color: bar),
                             TriVertex(pos: c + SIMD2(sx * cos(a0), sy * sin(a0)) * Float(rr), color: bar),
                             TriVertex(pos: c + SIMD2(sx * cos(a1), sy * sin(a1)) * Float(rr), color: bar)]
            }
        }
        var p2: [PointVertex] = [], t2: [TriVertex] = []
        let r2 = world.buildFrame(for: world.areas[0], dockLayer: true, points: &p2, tris: &t2)
        let o2 = dockTris.count
        dockTris += t2
        let db = gpu.device.makeBuffer(bytes: dockTris, length: dockTris.count * MemoryLayout<TriVertex>.stride)!
        enc.setRenderPipelineState(gpu.triPipeline); enc.setVertexBuffer(db, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: o2 + r2.caps)
        if !p2.isEmpty {
            let dp = gpu.device.makeBuffer(bytes: p2, length: p2.count * MemoryLayout<PointVertex>.stride)!
            enc.setRenderPipelineState(gpu.pointPipeline); enc.setVertexBuffer(dp, offset: 0, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: r2.balls)
            if r2.decor > r2.caps {
                enc.setRenderPipelineState(gpu.triPipeline); enc.setVertexBuffer(db, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: o2 + r2.caps, vertexCount: r2.decor - r2.caps)
            }
            if p2.count > r2.balls {
                enc.setRenderPipelineState(gpu.pointPipeline); enc.setVertexBuffer(dp, offset: 0, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: r2.balls, vertexCount: p2.count - r2.balls)
            }
        }
    }
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let w = tex.width, h = tex.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }       // BGRA → RGBA
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    bytes.withUnsafeBytes { _ = memcpy(rep.bitmapData!, $0.baseAddress!, bytes.count) }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print("  png  \(out)/\(name).png")
}

render("1-dark", lightWindows: false)
render("2-light", lightWindows: true)

// Dock со скрытием: положения — из настоящей записи анимации (Accessibility, шаг ~10 мс).
print("Dock выезжает и прячется:")
let dockUp: [CGFloat] = [956, 955, 953, 948, 945, 941, 937, 932, 927, 922, 917, 911, 905, 900, 895, 885, 876, 872, 869, 867, 865, 864, 863]
func dockStep(_ y: CGFloat, frames: Int = 1) {
    for _ in 0..<frames {
        now += 1.0 / 60
        world.setDock(CGRect(x: 94, y: y, width: 1282, height: 83), now: now)
        world.syncWindows(wins, now: now)
        world.step(dt: 1.0 / 60)
    }
}
Settings.shared.paused = true          // чтобы свежий снег не путал счёт
run(4)
let ground = world.areas[0].ground
func groundUnderDock() -> Float {
    var sum: Float = 0
    var x: Float = 100
    while x < 1370 { sum += ground.height(at: x); x += ground.cell }
    return sum * ground.cell
}
dockStep(956, frames: 3)
let lying = groundUnderDock()
let flakesBeforeDock = world.areas[0].flakes.count
// SNAP_FILM=1 — покадровая лента выезда/прятания Dock для глаз.
let film = ProcessInfo.processInfo.environment["SNAP_FILM"] != nil
for (k, y) in dockUp.enumerated() {
    dockStep(y)
    if film && k % 3 == 0 { render(String(format: "film-up-%02d", k), lightWindows: false) }
}
if film { for k in 0..<6 { dockStep(863, frames: 3); render(String(format: "film-top-%02d", k), lightWindows: false) } }
let onDock = world.dockState?.snow ?? 0
check(world.dockShown && world.dockState?.frame.minY == 863 + SnowWorld.dockPlatterTop, "Dock выехал, снег лежит на плашке: верх на \(world.dockState?.frame.minY ?? -1)")
check(lying > 1000 && groundUnderDock() < lying * 0.05, "сугроб над Dock подхвачен: у кромки было \(Int(lying)), осталось \(Int(groundUnderDock())) pt²")
check(onDock > lying * 0.6 && onDock < lying * 1.0, "на крыше Dock \(Int(onDock)) pt² из \(Int(lying)) — часть раскрошилась")
check(world.areas[0].flakes.count > flakesBeforeDock, "на подъёме снег крошится: снежинок \(flakesBeforeDock) → \(world.areas[0].flakes.count)")
let frontFlakes = world.areas[0].flakes.filter { $0.front }.count
check(frontFlakes >= 8, "снежная пыль и крошки с Dock летят перед окнами: \(frontFlakes)")
if let s = world.surfaces.first(where: { $0.isDock }) {
    // На дуге скруглённого угла снег есть и лежит по нормали к ней — облегает угол, наружу
    // за плашку почти не выходит.
    let x = s.b - s.corner * 0.3
    let g = s.base(at: x), h = s.map.height(at: x - s.originX)
    let outerX = x + g.nx * h
    check(g.y > s.y + 1 && h > 0.3 && outerX < s.b + 3,
          "снег облегает угол Dock: на дуге \(String(format: "%.1f", h)) pt, опора ниже кромки на \(String(format: "%.1f", g.y - s.y)), наружу за плашку \(String(format: "%.1f", outerX - s.b)) pt")
}
let man = world.balls
let crown = man.map { $0.y - $0.r }.min() ?? 956
let strip = world.dockLayerHeight(for: world.areas[0])
check(Float(H) - Float(strip) <= crown - 10,
      "полоса слоя Dock доросла до макушки снеговика: полоса \(Int(strip)) pt, макушка на \(Int(crown)) (верх полосы \(Int(H - strip)))")
check(man.count == 3 && man.allSatisfy { $0.onDock && $0.resting && $0.y + $0.r < 875 },
      "снеговик поднялся вместе с Dock: низы комьев \(man.map { Int($0.y + $0.r) }), на Dock: \(man.map { $0.onDock })")
run(0.15)
render("4-dock-up", lightWindows: false)
dockStep(863, frames: 60)
let settled = world.dockState?.snow ?? 0
// Dock уезжает со скоростью из записи: ~10 мс на шаг, то есть на кадр 60 Гц — пропускаем каждый
// третий отсчёт (~0.23 с на весь путь, как вживую).
var slabFrames = 0, sawSlab = false
for (k, y) in dockUp.reversed().enumerated() where k % 3 != 2 {
    dockStep(y)
    if world.dockSlabFalling { sawSlab = true; slabFrames += 1 }
    if ProcessInfo.processInfo.environment["SNAP_DEBUG"] != nil { print("    dock \(y) top=\(world.dockState?.frame.minY ?? -1) slab \(world.dockSlabDebug)") }
    if film && k % 3 == 0 { render(String(format: "film-down-%02d", k), lightWindows: false) }
}
check(sawSlab, "Dock пошёл вниз — снег сорвался пластом и падает сам, а не уезжает с ним")
while world.dockSlabFalling && slabFrames < 90 {
    dockStep(956)
    slabFrames += 1
    if film && slabFrames % 4 == 0 { render(String(format: "film-fall-%02d", slabFrames), lightWindows: false) }
}
check(!world.dockSlabFalling && slabFrames >= 10 && slabFrames <= 40,
      "пласт падал \(slabFrames) кадров (~\(slabFrames * 1000 / 60) мс) и лёг у кромки сразу за Dock")
check(world.dockGhostAlive, "у кромки снег тает на слое Dock, а не пропадает")
if film { for k in 0..<4 { render(String(format: "film-ghost-%02d", k), lightWindows: false); dockStep(956, frames: 8) } }
dockStep(956, frames: 60)
check(!world.dockGhostAlive, "тающая копия исчезла")
let back = groundUnderDock()
check(!world.dockShown && (world.dockState?.snow ?? 1) < 0.01, "Dock спрятался, на нём пусто")
check(back > settled * 0.75, "снег с Dock лёг обратно у кромки: \(Int(back)) pt² (на Dock было \(Int(settled)))")
run(1.5)
let down = world.balls
let lowest = down.max { $0.y < $1.y }
check(down.count == 3 && down.allSatisfy { !$0.onDock && $0.resting } && (lowest.map { $0.y + $0.r > 940 } ?? false),
      "снеговик опустился к кромке, не развалившись: низы комьев \(down.map { Int($0.y + $0.r) })")
Settings.shared.paused = false
world.setDock(nil, now: now)

// Снежки: скатать ком и бросить — теми же вызовами, что у мыши; скорость руки — mouseVel.
print("Снежки:")
var groundAfterRoll: Float = 0
func throwBall(from x0: Float, roll x1: Float, velocity v: SIMD2<Float>) -> Int? {
    let known = Set(world.balls.map { $0.id })
    roll(from: x0, to: x1)
    guard let id = world.balls.last?.id, !known.contains(id) else { return nil }
    groundAfterRoll = world.areas[0].ground.total
    world.mouseVel = v
    world.sculptUp()
    world.mouseVel = .zero
    return id
}
let manBefore = world.balls.map { ($0.id, $0.x, $0.y) }
if let id = throwBall(from: 300, roll: 360, velocity: SIMD2(700, -900)) {
    let groundBefore = groundAfterRoll
    check(world.balls.first { $0.id == id }?.flying == true, "отпустил на замахе — ком полетел")
    var t = 0, maxH: Float = 1e9
    while world.balls.contains(where: { $0.id == id }) && t < 240 {
        run(1.0 / 60); t += 1
        if let b = world.balls.first(where: { $0.id == id }) { maxH = min(maxH, b.y) }
    }
    check(!world.balls.contains { $0.id == id } && maxH < 800,
          "снежок пролетел дугой (верх дуги на \(Int(maxH)) pt) и разбился за \(t) кадров")
    check(world.areas[0].ground.total > groundBefore - 50, "снег от удара налип: сугроб \(Int(groundBefore)) → \(Int(world.areas[0].ground.total))")
}
// В снеговика: бросок низом вправо
if ProcessInfo.processInfo.environment["SNAP_DEBUG"] != nil {
    print("    комья до броска:", world.balls.map { "id\($0.id) x\(Int($0.x)) y\(Int($0.y)) r\(Int($0.r)) \($0.resting ? "стоит" : "")" })
    print("    сугроб у x=900…960:", (0..<4).map { String(format: "%.1f", world.areas[0].ground.height(at: Float(900 + $0 * 20))) })
}
if let target = manBefore.min(by: { $0.2 > $1.2 }), let id = throwBall(from: 900, roll: 960, velocity: SIMD2(1500, -260)) {
    if ProcessInfo.processInfo.environment["SNAP_DEBUG"] != nil {
        print("    бросок id\(id):", world.balls.first { $0.id == id }.map { "x\(Int($0.x)) y\(Int($0.y)) r\(Int($0.r)) летит \($0.flying)" } ?? "нет")
    }
    var t = 0
    while world.balls.contains(where: { $0.id == id }) && t < 120 { run(1.0 / 60); t += 1 }
    run(0.4)
    let moved = world.balls.contains { b in b.id == target.0 && (abs(b.x - target.1) > 3 || abs(b.y - target.2) > 3) }
        || !world.balls.contains { $0.id == target.0 }
    check(!world.balls.contains { $0.id == id } && moved, "снежок попал в снеговика и сбил ком")
}
// В край экрана
if let id = throwBall(from: 160, roll: 120, velocity: SIMD2(-1800, -300)) {
    var t = 0
    while world.balls.contains(where: { $0.id == id }) && t < 60 { run(1.0 / 60); t += 1 }
    check(!world.balls.contains { $0.id == id } && t < 30, "снежок разбился о край экрана за \(t) кадров")
}

// Медленное перетаскивание (300 pt/с, 1 с): снег частично держится.
print("Медленное перетаскивание окна 10:")
let slowBefore = world.surfaces.first { $0.window == 10 }!.map.total
for _ in 0..<60 {
    wins[0] = TrackedWindow(id: 10, frame: wins[0].frame.offsetBy(dx: 0, dy: -5), kind: .normal)
    now += 1.0 / 60
    world.syncWindows(wins, now: now)
    world.step(dt: 1.0 / 60)
}
let slowAfter = world.surfaces.first { $0.window == 10 }!.map.total
check(slowAfter > slowBefore * 0.4 && slowAfter < slowBefore * 0.9,
      "после секунды медленного перетаскивания осталось \(Int(slowAfter / max(slowBefore, 1) * 100))% снега")

// Рывок окна: снег слетает и уносится в сторону движения.
print("Рывок окна 11 вправо:")
let before = world.surfaces.first { $0.window == 11 }!.map.total
let flakesBefore = world.areas[0].flakes.count
for _ in 0..<6 {
    wins[1] = TrackedWindow(id: 11, frame: wins[1].frame.offsetBy(dx: 45, dy: 0), kind: .normal)
    now += 1.0 / 60
    world.syncWindows(wins, now: now)
    world.step(dt: 1.0 / 60)
}
let after = world.surfaces.first { $0.window == 11 }!.map.total
check(after < before * 0.6, "снег на окне 11: \(Int(before)) → \(Int(after)) pt²")
check(world.areas[0].flakes.count > flakesBefore, "слетевший снег стал снежинками: \(flakesBefore) → \(world.areas[0].flakes.count)")
run(0.25)
render("3-shake", lightWindows: false)

// Пряничный домик с ёлкой и участком.
print("Пряничный домик:")
world.scene.setEnabled(true)
if ProcessInfo.processInfo.environment["SNAP_FILM"] != nil {
    for k in 0..<8 { run(0.15); render(String(format: "film-house-%02d", k), lightWindows: false) }
}
run(1.6)
check(world.scene.solid && world.surfaces.filter { $0.slope != 0 }.count == 2, "домик вырос, скаты крыши стали кромками")
run(40)
check(world.scene.roofLeft.total > 40 && world.scene.roofRight.total > 40,
      "снег копится на крыше: \(Int(world.scene.roofLeft.total)) и \(Int(world.scene.roofRight.total)) pt²")
render("5-house", lightWindows: false)
func roofWidth() -> Float { world.surfaces.first { $0.slope < 0 }.map { $0.b - $0.a } ?? -1 }
let small = roofWidth()
world.setHouseScale(1.0)
let big = roofWidth()
world.setHouseScale(0.6)
check(abs(small - 41.4) < 0.5 && abs(big - 69) < 0.5 && abs(roofWidth() - 41.4) < 0.5,
      "размер домика переключается: скат \(small) → \(big) → \(roofWidth()) pt")
world.scene.setEnabled(false)
run(0.8)
check(!world.scene.solid && world.surfaces.allSatisfy { $0.slope == 0 }, "домик убран, крыша больше не кромка")

// Пряничный человечек: выходит, машет, копает сугроб у дома, возвращается.
print("Пряничный человечек:")
world.scene.setEnabled(true)
run(1.6)
let k = world.scene.scale, o = world.scene.anchor
func groundAt(_ sx: Float) -> Float { world.areas[0].ground.height(at: o.x + sx * k - Float(world.areas[0].bounds.minX)) }
// подсыпать снега у дома, чтобы было что копать
for sx in stride(from: Float(60), to: 140, by: 2) { world.areas[0].ground.deposit(at: o.x + sx * k, area: 30) }
let snowBefore = (95...110).map { groundAt(Float($0)) }.reduce(0, +)
Settings.shared.paused = true
world.areas[0].flakes.removeAll()      // летящий снег засыпал бы ямку и путал счёт
world.scene.visitSoon()
var seen: [String] = []
var frames = 0
let film2 = ProcessInfo.processInfo.environment["SNAP_FILM"] != nil
while frames < 60 * 14 {
    run(1.0 / 60); frames += 1
    let ph = world.scene.manPhase
    if seen.last != ph {
        seen.append(ph)
        if film2 && (ph == "wave" || ph == "dig" || ph == "walkBack") { run(0.3); frames += 18; render("man-\(ph)", lightWindows: false) }
    }
    if seen.count > 2 && ph == "inside" { break }
}
let snowAfter = (95...110).map { groundAt(Float($0)) }.reduce(0, +)
check(seen == ["opening", "walkOut", "wave", "dig", "walkBack", "entering", "closing", "inside"],
      "человечек прошёл весь путь: \(seen.joined(separator: " → ")) за \(String(format: "%.1f", Float(frames) / 60)) с")
check(snowAfter < snowBefore * 0.75, "расчистил сугроб у дома: \(Int(snowBefore)) → \(Int(snowAfter))")
Settings.shared.paused = false

// Экскаватор при пустом сугробе (как сразу после запуска): раньше зацикливался и ронял приложение.
print("Экскаватор на пустом сугробе:")
do {
    let empty = SnowWorld()
    empty.setScreens([(1, CGRect(x: 0, y: 0, width: W, height: H))])
    Settings.shared.paused = true
    empty.excavator.setEnabled(true)
    var phases: [String] = []
    for _ in 0..<(60 * 12) {
        empty.step(dt: 1.0 / 60)
        let ph = empty.excavator.phaseName
        if phases.last != ph { phases.append(ph) }
    }
    check(phases.contains("leaving") && phases.last == "resting",
          "снега нет — въехал, развернулся и уехал отдыхать: \(phases.joined(separator: " → "))")
    Settings.shared.paused = false
}

// Экскаватор: въезжает справа, сгребает сугроб в кучу фиксированного размера, высыпает за правый край, уезжает.
print("Экскаватор:")
Settings.shared.paused = true
let ar = world.areas[0]
var gx = Float(ar.bounds.minX)
while gx < Float(ar.bounds.maxX) { ar.ground.deposit(at: gx - Float(ar.bounds.minX), area: 2.5 * 10); gx += 2.5 }
run(0.5)
let groundFull = ar.ground.total
world.excavator.setEnabled(true)
var exPhases: [String] = []
var maxLoad: Float = 0, flewOut = 0, exFrames = 0
var workMin = Float.greatestFiniteMagnitude, workMax: Float = -1
let filmEx = ProcessInfo.processInfo.environment["SNAP_FILM"] != nil
while exFrames < 60 * 90 {
    run(1.0 / 60); exFrames += 1
    let ph = world.excavator.phaseName
    if exPhases.last != ph {
        exPhases.append(ph)
        if ProcessInfo.processInfo.environment["SNAP_DEBUG"] != nil {
            print(String(format: "    %5.1fс %@ %@", Float(exFrames) / 60, ph, world.excavator.debugState))
        }
        if filmEx && ["carrying", "dumping"].contains(ph) { run(0.5); exFrames += 30; render("ex-\(ph)", lightWindows: false) }
    }
    if filmEx && exFrames == 240 { render("ex-collecting", lightWindows: false) }
    maxLoad = max(maxLoad, world.excavator.load)
    if ph == "collecting" { workMin = min(workMin, world.excavator.workX); workMax = max(workMax, world.excavator.workX) }
    flewOut = max(flewOut, ar.flakes.filter { $0.x > Float(ar.bounds.maxX) }.count)
    if ph == "resting" { break }
}
let groundAfterFirst = ar.ground.total
let dumps = exPhases.filter { $0 == "dumping" }.count
let visit = Float(exFrames) / 60
check(exPhases.first == "arriving" && exPhases.contains("collecting") && dumps >= 1 && exPhases.last == "resting" && visit >= 12 && visit <= 30,
      "экскаватор работал \(String(format: "%.1f", visit)) с и высыпал \(dumps) раз: \(exPhases.joined(separator: " → "))")
// Ещё два приезда (отдых пропускаем): каждый — в свою треть кромки, вместе — по всей.
for _ in 0..<2 {
    world.excavator.comeBackNow()
    var f = 0
    repeat {
        run(1.0 / 60); f += 1
        if world.excavator.phaseName == "collecting" {
            workMin = min(workMin, world.excavator.workX); workMax = max(workMax, world.excavator.workX)
        }
    } while world.excavator.phaseName != "resting" && f < 60 * 60
    for i in stride(from: Float(ar.bounds.minX), to: Float(ar.bounds.maxX), by: 2.5) { ar.ground.deposit(at: i - Float(ar.bounds.minX), area: 25) }
}
let span = Float(ar.bounds.width)
check(workMax - workMin > span * 0.55, "за три приезда убирал по всей кромке: от \(Int(workMin)) до \(Int(workMax)) pt из \(Int(span))")
check(maxLoad >= world.excavator.capacity - 1, "набрал полный ковш: \(Int(maxLoad)) из \(Int(world.excavator.capacity)) pt²")
check(flewOut > 10, "снег из ковша улетел за правый край: \(flewOut) снежинок за экраном")
check(groundAfterFirst < groundFull - world.excavator.capacity * 0.8, "сугроб убыл: \(Int(groundFull)) → \(Int(groundAfterFirst)) pt²")
var restFrames = 0
while world.excavator.phaseName == "resting" && restFrames < 60 * 60 { run(1.0 / 60); restFrames += 1 }
let period = visit + Float(restFrames) / 60
check(period > 37 && period < 44, "следующий приезд через \(String(format: "%.1f", period)) с от начала прошлого")
world.excavator.comeBackNow()
run(0.2)
check(["arriving", "collecting"].contains(world.excavator.phaseName), "после отдыха въезжает снова: \(world.excavator.phaseName)")
world.excavator.setEnabled(false)
run(3)
check(!world.excavator.visible, "выключили — уехал за край и пропал")
Settings.shared.paused = false

// Два экрана: домик и экскаватор переезжают на второй, при его отключении — на основной, при
// возвращении — назад (настройка помнит экран по ключу дисплея).
print("Несколько экранов:")
do {
    Settings.shared.paused = true
    let two = SnowWorld()
    let b1 = CGRect(x: 0, y: 0, width: W, height: H), b2 = CGRect(x: W, y: -60, width: 1920, height: 1080)
    two.setScreens([(1, b1), (2, b2)])
    let a1 = two.areas[0], a2 = two.areas[1]
    for a in [a1, a2] {
        var x = Float(a.bounds.minX)
        while x < Float(a.bounds.maxX) { a.ground.deposit(at: x - Float(a.bounds.minX), area: 2.5 * 10); x += 2.5 }
    }
    two.scene.setEnabled(true)
    for _ in 0..<90 { two.step(dt: 1.0 / 60) }
    check(two.sceneArea === a1 && !a1.surfaces.isEmpty && a2.surfaces.isEmpty, "по умолчанию домик на основном экране")
    two.setSceneScreen(a2.key)
    two.setExcavatorScreen(a2.key)
    for _ in 0..<90 { two.step(dt: 1.0 / 60) }      // домик вырос на новом месте
    check(two.sceneArea === a2 && a1.surfaces.isEmpty && !a2.surfaces.isEmpty,
          "домик переехал на второй экран, крыша принимает снег там: кромок \(a1.surfaces.count) / \(a2.surfaces.count)")
    var p: [PointVertex] = [], t1: [TriVertex] = [], t2: [TriVertex] = []
    _ = two.buildFrame(for: a1, points: &p, tris: &t1)
    _ = two.buildFrame(for: a2, points: &p, tris: &t2)
    check(t2.count > t1.count + 200, "рисуется только на втором: треугольников \(t1.count) / \(t2.count)")
    // Человечек копает у дома на втором экране.
    let houseX = Float(b2.minX) + 60
    let snow2 = a2.ground.height(at: houseX + 40 - Float(b2.minX))
    two.scene.visitSoon()
    var f = 0, out = false
    repeat {
        two.step(dt: 1.0 / 60); f += 1
        if two.scene.manPhase != "inside" { out = true }
    } while !(out && two.scene.manPhase == "inside") && f < 60 * 40
    let dug = (Int(houseX)...Int(houseX) + 80).map { a2.ground.height(at: Float($0) - Float(b2.minX)) }.min() ?? 99
    check(out && dug < snow2 - 1, "человечек вышел и копал на втором экране: сугроб \(String(format: "%.1f", snow2)) → \(String(format: "%.1f", dug))")
    // Экскаватор убирает второй экран, основной не трогает.
    let g1 = a1.ground.total, g2 = a2.ground.total
    two.excavator.setEnabled(true)
    var xs: [Float] = []
    f = 0
    repeat {
        two.step(dt: 1.0 / 60); f += 1
        if two.excavator.phaseName == "collecting" { xs.append(two.excavator.workX) }
    } while two.excavator.phaseName != "resting" && f < 60 * 40
    let inside2 = !xs.isEmpty && xs.allSatisfy { $0 > Float(b2.minX) && $0 < Float(b2.maxX) }
    check(inside2 && a2.ground.total < g2 - 500 && abs(a1.ground.total - g1) < 1,
          "экскаватор работал на втором: x \(Int(xs.min() ?? 0))…\(Int(xs.max() ?? 0)), сугроб \(Int(g2)) → \(Int(a2.ground.total)), на основном без изменений")
    // Второй экран отключили — всё на основном; вернули — назад.
    two.excavator.comeBackNow()
    for _ in 0..<30 { two.step(dt: 1.0 / 60) }
    two.setScreens([(1, b1)])
    for _ in 0..<90 { two.step(dt: 1.0 / 60) }      // домик заново вырастает ~1 с
    check(two.sceneArea === two.areas[0] && !two.areas[0].surfaces.isEmpty && two.excavator.bounds.maxX == Float(W)
          && two.excavator.workX > Float(W) - 200 && two.excavator.workX < Float(W) + 100,
          "второй экран отключили — домик и экскаватор на основном (x=\(Int(two.excavator.workX)), \(two.excavator.phaseName))")
    two.setScreens([(1, b1), (2, b2)])
    for _ in 0..<30 { two.step(dt: 1.0 / 60) }
    check(two.sceneArea?.key == a2.key && two.excavatorArea?.key == a2.key && two.excavator.bounds.minX == Float(W),
          "вернули — оба снова на втором")
    two.setSceneScreen(a1.key)
    for _ in 0..<5 { two.step(dt: 1.0 / 60) }
    check(two.sceneArea === two.areas[0] && two.excavatorArea === two.areas[1], "домик и экскаватор — на разных экранах")
    Settings.shared.paused = false
}

print(failures == 0 ? "Все проверки прошли" : "Провалено проверок: \(failures)")
exit(failures == 0 ? 0 : 1)
