import AppKit
import MetalKit

final class OverlayWindow: NSWindow {
    var interactive = false
    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }
}

/// Прозрачный слой со снегом. Мышь получает только в режиме лепки.
final class SnowView: MTKView {
    weak var world: SnowWorld?
    var interactive = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if interactive { addCursorRect(bounds, cursor: .openHand) }
    }

    private func point(_ e: NSEvent) -> SIMD2<Float> {
        guard let w = window else { return .zero }
        return Geo.cg(w.convertPoint(toScreen: e.locationInWindow))
    }
    override func mouseDown(with e: NSEvent) { world?.sculptDown(point(e)); NSCursor.closedHand.set() }
    override func mouseDragged(with e: NSEvent) { world?.sculptDrag(point(e)) }
    override func mouseUp(with e: NSEvent) { world?.sculptUp(); NSCursor.openHand.set() }
}

final class Overlay {
    /// Высота полосы над нижней кромкой, где рисуется снег на Dock: Dock (~83 pt) + отступ + шапка.
    static let dockStrip: CGFloat = 170

    let screen: NSScreen
    /// Основной слой: снегопад, сугробы на окнах и у кромки, снежки.
    let window: OverlayWindow
    let view: SnowView
    let renderer: ScreenRenderer
    /// Тонкий слой прямо над Dock: только снег на Dock — он лежит перед окнами, как и сам Dock.
    let dockWindow: OverlayWindow
    let dockView: SnowView
    let dockRenderer: ScreenRenderer

    init(screen: NSScreen, area: ScreenArea, world: SnowWorld) {
        self.screen = screen
        window = Overlay.makeWindow(screen.frame)
        view = Overlay.makeView(screen.frame.size, world)
        renderer = ScreenRenderer(area: area, world: world)
        view.delegate = renderer
        window.contentView = view

        let strip = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: Overlay.dockStrip)
        dockWindow = Overlay.makeWindow(strip)
        dockWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        dockView = Overlay.makeView(strip.size, world)
        let region = CGRect(x: area.bounds.minX, y: area.bounds.maxY - Overlay.dockStrip,
                            width: area.bounds.width, height: Overlay.dockStrip)
        dockRenderer = ScreenRenderer(area: area, world: world, dockLayer: true, region: region)
        dockView.delegate = dockRenderer
        dockWindow.contentView = dockView

        setRenderScale(eco: world.eco)
        // Снег идёт на рабочем столе: сразу над обоями и значками, под виджетами (+2), окнами и Dock.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.orderFrontRegardless()
        dockWindow.orderFrontRegardless()
    }

    private static func makeWindow(_ frame: NSRect) -> OverlayWindow {
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        return w
    }

    private static func makeView(_ size: NSSize, _ world: SnowWorld) -> SnowView {
        let v = SnowView(frame: NSRect(origin: .zero, size: size), device: GPU.shared.device)
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColorMake(0, 0, 0, 0)
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        v.framebufferOnly = true
        v.autoResizeDrawable = false
        v.wantsLayer = true
        v.layer?.isOpaque = false
        v.layer?.backgroundColor = .clear
        // Кадры обоих слоёв (рабочий стол и Dock) уходят на экран одной транзакцией Core Animation:
        // когда снег переходит со слоя на слой, не бывает кадра, где его нет ни там, ни там.
        (v.layer as? CAMetalLayer)?.presentsWithTransaction = true
        v.world = world
        return v
    }

    /// Снег мягкий — полная Retina ему не нужна. 1.5x на глаз не отличить от 2x, а кадр
    /// весит 12.6 МБ вместо 22.5 МБ; в режиме энергосбережения — 1x.
    func setRenderScale(eco: Bool) {
        let scale = min(screen.backingScaleFactor, eco ? 1 : 1.5)
        renderer.scale = Float(scale)
        dockRenderer.scale = Float(scale)
        view.drawableSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        dockView.drawableSize = CGSize(width: screen.frame.width * scale, height: Overlay.dockStrip * scale)
    }

    func draw() {
        view.draw()
        dockView.draw()
    }

    func hide() {
        window.orderOut(nil)
        dockWindow.orderOut(nil)
    }

    func setInteractive(_ on: Bool) {
        window.interactive = on
        window.ignoresMouseEvents = !on
        view.interactive = on
    }
}
