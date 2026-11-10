// Проверка без экрана: симуляция на выдуманных окнах + отрисовка теми же шейдерами в PNG.
//   ./tests/snapshot.sh <папка для png>
import AppKit
import Metal

let W: CGFloat = 1470, H: CGFloat = 956, S: CGFloat = 2
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
check(capHeight(11, 840) > 3, "на окне 11 лежит снег: \(capHeight(11, 840)) pt")
check(capHeight(13, 145) > 1, "на виджете 13 лежит снег: \(capHeight(13, 145)) pt")
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
    var bg: [TriVertex] = []
    rect(&bg, CGRect(x: 0, y: 0, width: W, height: H), SIMD4(0.10, 0.16, 0.27, 1), SIMD4(0.20, 0.30, 0.38, 1))
    for w in wins.reversed() {
        let body: SIMD4<Float> = lightWindows ? SIMD4(1, 1, 1, 1) : SIMD4(0.16, 0.17, 0.19, 1)
        let bar: SIMD4<Float> = lightWindows ? SIMD4(0.93, 0.93, 0.94, 1) : SIMD4(0.22, 0.23, 0.25, 1)
        rect(&bg, w.frame, body, body)
        rect(&bg, CGRect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: 28), bar, bar)
    }
    var points: [PointVertex] = [], tris: [TriVertex] = []
    let r = world.buildFrame(for: world.areas[0], points: &points, tris: &tris)
    let all = bg + tris
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

print(failures == 0 ? "Все проверки прошли" : "Провалено проверок: \(failures)")
exit(failures == 0 ? 0 : 1)
