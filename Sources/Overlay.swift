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
    let screen: NSScreen
    let window: OverlayWindow
    let view: SnowView
    let renderer: ScreenRenderer

    init(screen: NSScreen, area: ScreenArea, world: SnowWorld) {
        self.screen = screen
        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        view = SnowView(frame: NSRect(origin: .zero, size: screen.frame.size), device: GPU.shared.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        renderer = ScreenRenderer(area: area, world: world)
        view.delegate = renderer
        view.world = world
        window.contentView = view
        setRenderScale(eco: world.eco)
        setLayer(overWindows: Settings.shared.overWindows)
        window.orderFrontRegardless()
    }

    /// Поверх окон: над окнами и Dock (20), под строкой меню (24) — значок в строке меню всегда нажимается.
    /// За окнами: сразу над обоями и значками рабочего стола, под виджетами (+2), окнами и Dock.
    func setLayer(overWindows: Bool) {
        window.level = overWindows
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 3)
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.orderFrontRegardless()
    }

    /// Снег мягкий — полная Retina ему не нужна. 1.5x на глаз не отличить от 2x, а кадр
    /// весит 12.6 МБ вместо 22.5 МБ; в режиме энергосбережения — 1x.
    func setRenderScale(eco: Bool) {
        let scale = min(screen.backingScaleFactor, eco ? 1 : 1.5)
        renderer.scale = Float(scale)
        view.drawableSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    func setInteractive(_ on: Bool) {
        window.interactive = on
        window.ignoresMouseEvents = !on
        view.interactive = on
    }
}
