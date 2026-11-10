import MetalKit

// Раскладка в памяти совпадает со структурами в шейдере (по 32 байта).
struct PointVertex {
    var pos: SIMD2<Float>
    var size: Float
    var alpha: Float
    /// rgb + вид: 0 — снежинка, 1 — снежный шар, 2 — уголёк.
    var color: SIMD4<Float>
}

struct TriVertex {
    var pos: SIMD2<Float>
    var pad = SIMD2<Float>(0, 0)
    var color: SIMD4<Float>
    init(pos: SIMD2<Float>, color: SIMD4<Float>) { self.pos = pos; self.color = color }
}

struct Uniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var scale: Float
    var pad: Float = 0
}

/// Шейдеры собираются при запуске: Xcode для сборки не нужен.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U  { float2 origin; float2 size; float scale; };
struct PV { float2 pos; float size; float alpha; float4 color; };
struct TV { float2 pos; float2 pad; float4 color; };
struct PO { float4 position [[position]]; float psize [[point_size]]; float alpha; float4 color; };
struct TO { float4 position [[position]]; float4 color; };

static float2 ndc(float2 p, constant U& u) {
    return float2((p.x - u.origin.x) / u.size.x * 2.0 - 1.0, 1.0 - (p.y - u.origin.y) / u.size.y * 2.0);
}

vertex PO pointVS(uint vid [[vertex_id]], const device PV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    PV p = v[vid];
    PO o;
    o.position = float4(ndc(p.pos, u), 0.0, 1.0);
    o.psize = max(p.size * u.scale, 1.0);
    o.alpha = p.alpha;
    o.color = p.color;
    return o;
}

fragment float4 pointFS(PO in [[stage_in]], float2 pc [[point_coord]]) {
    float2 d = pc * 2.0 - 1.0;
    float r = length(d);
    if (r > 1.0) discard_fragment();
    float kind = in.color.w;
    float3 c;
    float a;
    if (kind < 0.5) {
        // Снежинка: плавный переход от белого центра к прохладному краю — без колечка,
        // но на белой странице она остаётся видна как мягкое серо-голубое пятнышко.
        a = 1.0 - smoothstep(0.2, 1.0, r);
        c = mix(float3(0.80, 0.84, 0.91), float3(1.0), 1.0 - r * r);
    } else if (kind < 1.5) {
        // Снежный шар: объём от простого освещения.
        float z = sqrt(max(0.0, 1.0 - r * r));
        float3 n = float3(d.x, -d.y, z);
        float diff = saturate(dot(n, normalize(float3(-0.45, 0.55, 0.7))));
        c = mix(float3(0.70, 0.76, 0.87), float3(1.0), diff * 0.85 + 0.15);
        a = 1.0 - smoothstep(0.93, 1.0, r);
    } else {
        c = in.color.rgb;
        a = 1.0 - smoothstep(0.7, 1.0, r);
    }
    a *= in.alpha;
    return float4(c * a, a);
}

vertex TO triVS(uint vid [[vertex_id]], const device TV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    TO o;
    o.position = float4(ndc(v[vid].pos, u), 0.0, 1.0);
    o.color = v[vid].color;
    return o;
}

fragment float4 triFS(TO in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}
"""

final class GPU {
    static let shared = GPU()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pointPipeline: MTLRenderPipelineState
    let triPipeline: MTLRenderPipelineState

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal недоступен")
        }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderSource, options: nil) }
        catch { fatalError("Шейдеры не собрались: \(error)") }

        func pipeline(_ vs: String, _ fs: String) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { return try device.makeRenderPipelineState(descriptor: d) }
            catch { fatalError("Конвейер \(vs)/\(fs): \(error)") }
        }
        pointPipeline = pipeline("pointVS", "pointFS")
        triPipeline = pipeline("triVS", "triFS")
    }
}

/// Рисует снег одного экрана. Вершины пишутся в кольцо из трёх буферов,
/// чтобы не перезаписывать то, что ещё читает видеокарта.
final class ScreenRenderer: NSObject, MTKViewDelegate {
    let area: ScreenArea
    private unowned let world: SnowWorld
    private var points: [PointVertex] = []
    private var tris: [TriVertex] = []
    private var ring: [(points: MTLBuffer, tris: MTLBuffer)] = []
    private var slot = 0
    private let inflight = DispatchSemaphore(value: 3)

    init(area: ScreenArea, world: SnowWorld) {
        self.area = area
        self.world = world
        super.init()
        for _ in 0..<3 { ring.append((buffer(64 * 1024), buffer(256 * 1024))) }
    }

    private func buffer(_ length: Int) -> MTLBuffer {
        GPU.shared.device.makeBuffer(length: length, options: .storageModeShared)!
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        inflight.wait()
        let r = world.buildFrame(for: area, points: &points, tris: &tris)
        slot = (slot + 1) % ring.count
        let pBytes = points.count * MemoryLayout<PointVertex>.stride
        let tBytes = tris.count * MemoryLayout<TriVertex>.stride
        if ring[slot].points.length < pBytes { ring[slot].points = buffer(pBytes * 2) }
        if ring[slot].tris.length < tBytes { ring[slot].tris = buffer(tBytes * 2) }
        let pb = ring[slot].points, tb = ring[slot].tris
        if pBytes > 0 { points.withUnsafeBytes { pb.contents().copyMemory(from: $0.baseAddress!, byteCount: pBytes) } }
        if tBytes > 0 { tris.withUnsafeBytes { tb.contents().copyMemory(from: $0.baseAddress!, byteCount: tBytes) } }

        let gpu = GPU.shared
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = gpu.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            return
        }
        var u = Uniforms(origin: SIMD2(Float(area.bounds.minX), Float(area.bounds.minY)),
                         size: SIMD2(Float(area.bounds.width), Float(area.bounds.height)),
                         scale: Float(view.window?.backingScaleFactor ?? 2))
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        // Порядок слоёв: сугробы → шары → морковки → угольки и снежинки.
        if r.caps > 0 {
            enc.setRenderPipelineState(gpu.triPipeline)
            enc.setVertexBuffer(tb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: r.caps)
        }
        if r.balls > 0 {
            enc.setRenderPipelineState(gpu.pointPipeline)
            enc.setVertexBuffer(pb, offset: 0, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: r.balls)
        }
        if r.decor > r.caps {
            enc.setRenderPipelineState(gpu.triPipeline)
            enc.setVertexBuffer(tb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: r.caps, vertexCount: r.decor - r.caps)
        }
        if points.count > r.balls {
            enc.setRenderPipelineState(gpu.pointPipeline)
            enc.setVertexBuffer(pb, offset: 0, index: 0)
            enc.drawPrimitives(type: .point, vertexStart: r.balls, vertexCount: points.count - r.balls)
        }
        enc.endEncoding()
        cmd.present(drawable)
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.commit()
    }
}
