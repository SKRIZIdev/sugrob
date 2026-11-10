import AppKit
import ApplicationServices
import QuartzCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let world = SnowWorld()
    private let tracker = WindowTracker()
    private let settings = Settings.shared
    private var overlays: [Overlay] = []
    private var statusItem: NSStatusItem!
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var nextPoll: CFTimeInterval = 0
    private var fastPollUntil: CFTimeInterval = 0
    private var nextDockPoll: CFTimeInterval = 0
    private var lastMouse: SIMD2<Float>?
    private var enabled = true
    private var asleep = false
    private var keyMonitor: Any?
    private var axTrusted: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--fast") { world.depositBoost = 12 }
        setupStatusItem()
        rebuildOverlays()
        observe()
        updateEco()
        startLink()
        if args.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.world.demo() }
        }
    }

    // MARK: Цикл кадров

    private func startLink() {
        link?.invalidate()
        link = nil
        guard enabled, !asleep, let view = overlays.first?.view else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = frameRange
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = 0
    }

    private var frameRange: CAFrameRateRange {
        world.eco ? CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
                  : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    @objc private func tick(_ l: CADisplayLink) {
        let workStart = CACurrentMediaTime()
        let now = l.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : now - lastTick
        lastTick = now

        let m = Geo.cg(NSEvent.mouseLocation)
        if let last = lastMouse {
            let v = (m - last) / Float(max(dt, 1.0 / 240))
            world.mouseVel = world.mouseVel * 0.5 + v * 0.5
        }
        lastMouse = m
        world.mouse = m

        // Опрос окон — самое дорогое в цикле (~4 мс). В покое 6 раз в секунду; пока зажата
        // кнопка мыши (окно могут тащить) или что-то только что двигалось — каждый кадр,
        // чтобы снег не отставал от окна.
        let dragging = NSEvent.pressedMouseButtons != 0
        if dragging || now >= nextPoll {
            if world.syncWindows(tracker.poll(), now: now) { fastPollUntil = now + 0.5 }
            nextPoll = now < fastPollUntil ? now : now + 1.0 / 6
        }
        // Dock: пока он на экране или курсор у нижней кромки (сейчас выедет) — каждый кадр,
        // чтобы снег ехал вместе с ним; иначе 4 раза в секунду.
        let cocoa = NSEvent.mouseLocation
        let nearBottom = overlays.contains { o in
            o.screen.frame.minX <= cocoa.x && cocoa.x < o.screen.frame.maxX && cocoa.y - o.screen.frame.minY < 14
        }
        if world.dockShown || nearBottom || now >= nextDockPoll {
            world.setDock(tracker.dockFrame(), now: now)
            nextDockPoll = now + 0.25
            // Для диагностики: `defaults read com.ivan.sugrob diag.axTrusted`.
            let ax = AXIsProcessTrusted()
            if ax != axTrusted { axTrusted = ax; UserDefaults.standard.set(ax, forKey: "diag.axTrusted") }
        }
        world.step(dt: Float(dt))
        if world.needsRedraw {
            for o in overlays {
                o.fitDockStrip(world.dockLayerHeight(for: o.renderer.area))
                o.draw()
            }
        }
        measure(now: now, dt: dt, work: CACurrentMediaTime() - workStart)
    }

    // MARK: Замер плавности, пока двигается Dock
    // `defaults read com.ivan.sugrob diag.dock` — последние движения Dock: кадров, пропусков, худший
    // интервал между кадрами и худшее время нашей работы в кадре.

    private var dockStats: (frames: Int, slow: Int, maxGap: Double, maxWork: Double, sumWork: Double)?
    private var dockLog: [String] = []

    private func measure(now: CFTimeInterval, dt: CFTimeInterval, work: CFTimeInterval) {
        if world.dockBusy {
            var s = dockStats ?? (0, 0, 0, 0, 0)
            s.frames += 1
            if s.frames > 1 {
                if dt > 1.5 / 60 { s.slow += 1 }
                s.maxGap = max(s.maxGap, dt)
            }
            s.maxWork = max(s.maxWork, work)
            s.sumWork += work
            dockStats = s
        } else if let s = dockStats {
            dockStats = nil
            let line = String(format: "кадров %d, пропусков %d, худший интервал %.1f мс, работа в кадре: худшая %.1f мс, средняя %.1f мс",
                              s.frames, s.slow, s.maxGap * 1000, s.maxWork * 1000, s.sumWork / Double(max(s.frames, 1)) * 1000)
            dockLog = Array((dockLog + [line]).suffix(8))
            UserDefaults.standard.set(dockLog, forKey: "diag.dock")
        }
    }

    // MARK: Экраны и состояние системы

    private func rebuildOverlays() {
        for o in overlays { o.hide() }
        overlays.removeAll()
        let screens = NSScreen.screens
        world.setScreens(screens.map { s in
            let id = Geo.displayID(s)
            return (id, CGDisplayBounds(id))
        })
        guard enabled else { return }
        for s in screens {
            let id = Geo.displayID(s)
            if let area = world.areas.first(where: { $0.id == id }) {
                overlays.append(Overlay(screen: s, area: area, world: world))
            }
        }
        applyTool()
    }

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildOverlays()
            self?.startLink()
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.updateEco() }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateEco() }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = true
                self?.link?.invalidate()
                self?.link = nil
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = false
                self?.startLink()
            }
        }
    }

    /// Экономный режим (вручную, при энергосбережении или перегреве) — вдвое меньше снега,
    /// 30 кадров в секунду, кадр в 1x.
    private func updateEco() {
        let info = ProcessInfo.processInfo
        world.eco = settings.eco || info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        link?.preferredFrameRateRange = frameRange
        for o in overlays { o.setRenderScale(eco: world.eco) }
    }

    // MARK: Инструменты

    private func applyTool() {
        let sculpt = settings.tool == .sculpt
        for o in overlays { o.setInteractive(sculpt) }
        if sculpt {
            NSApp.activate(ignoringOtherApps: true)
            overlays.first?.window.makeKey()
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    guard e.keyCode == 53 else { return e }      // Esc
                    self?.settings.tool = .none
                    self?.applyTool()
                    return nil
                }
            }
        } else {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            world.sculptUp()
        }
    }

    // MARK: Меню

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Сугроб")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = settings

        menu.addItem(item(s.paused ? "Продолжить снегопад" : "Остановить снегопад", #selector(togglePause)))
        menu.addItem(.separator())
        for i in Intensity.allCases {
            menu.addItem(item(i.title, #selector(setIntensity(_:)), tag: i.rawValue, on: s.intensity == i))
        }
        menu.addItem(.separator())

        let wind = NSMenu()
        for w in Wind.allCases { wind.addItem(item(w.title, #selector(setWind(_:)), tag: w.rawValue + 2, on: s.wind == w)) }
        wind.addItem(.separator())
        wind.addItem(item("Порывы", #selector(toggleGusts), on: s.gusts))
        menu.addItem(submenu("Ветер: \(s.wind.title.lowercased())", wind))

        let mouse = NSMenu()
        mouse.addItem(item("Обычный курсор", #selector(setTool(_:)), tag: Tool.none.rawValue, on: s.tool == .none))
        mouse.addItem(item("Сметать снег курсором", #selector(setTool(_:)), tag: Tool.mitten.rawValue, on: s.tool == .mitten))
        mouse.addItem(item("Лепить снежки (Esc — выход)", #selector(setTool(_:)), tag: Tool.sculpt.rawValue, on: s.tool == .sculpt))
        mouse.addItem(.separator())
        mouse.addItem(item("Снежинки разлетаются от курсора", #selector(togglePush), on: s.cursorPush))
        menu.addItem(submenu("Мышь", mouse))
        menu.addItem(.separator())

        menu.addItem(item("Снег ложится на окна", #selector(toggleAccumulate), on: s.accumulate))
        if AXIsProcessTrusted() {
            let dock = item("Снег ложится на Dock", #selector(noop), on: true)
            dock.isEnabled = false
            menu.addItem(dock)
        } else {
            menu.addItem(item("Снег на Dock: дать доступ…", #selector(requestDockAccess)))
        }
        menu.addItem(item("Убрать весь снег", #selector(shovel)))
        menu.addItem(.separator())
        menu.addItem(item("Экономный режим", #selector(toggleEco), on: settings.eco))
        menu.addItem(item("Запускать при входе", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item(enabled ? "Спрятать снег" : "Показать снег", #selector(toggleEnabled)))
        menu.addItem(item("Выйти", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0, on: Bool = false, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.tag = tag
        it.state = on ? .on : .off
        return it
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    @objc private func noop() {}
    @objc private func togglePause() { settings.paused.toggle() }
    @objc private func setIntensity(_ sender: NSMenuItem) { settings.intensity = Intensity(rawValue: sender.tag) ?? .steady }
    @objc private func setWind(_ sender: NSMenuItem) { settings.wind = Wind(rawValue: sender.tag - 2) ?? .calm }
    @objc private func toggleGusts() { settings.gusts.toggle() }
    @objc private func togglePush() { settings.cursorPush.toggle() }
    @objc private func setTool(_ sender: NSMenuItem) {
        settings.tool = Tool(rawValue: sender.tag) ?? .none
        applyTool()
    }
    @objc private func toggleAccumulate() {
        settings.accumulate.toggle()
        world.rebuildSurfaces()
    }
    @objc private func requestDockAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([key: false] as CFDictionary) { return }
        let alert = NSAlert()
        alert.messageText = "Снегу на Dock нужен «Универсальный доступ»"
        alert.informativeText = """
            По нему Сугроб узнаёт, где на экране Dock. Содержимое окон не читается.

            Если «Сугроб» уже есть в списке, но включён, — удалите его кнопкой «−» и включите снова: \
            старое разрешение было выдано другой сборке и к этой не подходит.
            """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func shovel() { world.shovel() }
    @objc private func toggleEco() {
        settings.eco.toggle()
        updateEco()
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не получилось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled {
            rebuildOverlays()
            startLink()
        } else {
            settings.tool = .none
            applyTool()
            link?.invalidate()
            link = nil
            for o in overlays { o.hide() }
            overlays.removeAll()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
