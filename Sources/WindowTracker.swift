import AppKit
import ApplicationServices

struct TrackedWindow {
    enum Kind { case normal, widget, panel }
    let id: CGWindowID
    /// Глобальные CG-координаты: y вниз, minY — верхняя кромка окна.
    let frame: CGRect
    let kind: Kind
}

/// Где на экране окна. Нужны только рамки — содержимое окон не читается,
/// поэтому разрешение на запись экрана не требуется.
final class WindowTracker {
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var bundles: [pid_t: String] = [:]
    /// Сколько обычных окон Finder на экране при последнем опросе.
    private(set) var finderWindows = 0

    /// Окна, на которые может лечь снег, спереди назад.
    func poll() -> [TrackedWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [TrackedWindow] = []
        out.reserveCapacity(48)
        var finder = 0
        defer { finderWindows = finder }
        for info in raw {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let b = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            let frame = CGRect(x: num(b["X"]), y: num(b["Y"]), width: num(b["Width"]), height: num(b["Height"]))
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05, frame.width >= 60, frame.height >= 30 else { continue }

            let kind: TrackedWindow.Kind
            if layer == 0 {
                kind = .normal
                if bundleID(pid) == "com.apple.finder" { finder += 1 }
            } else {
                let bundle = bundleID(pid)
                if bundle == "com.apple.notificationcenterui", layer < 0, frame.width < 800, frame.height < 800 {
                    kind = .widget          // виджеты на рабочем столе
                } else if bundle == "com.apple.Spotlight", layer > 0, layer < 100, frame.height < 800 {
                    kind = .panel
                } else {
                    continue
                }
            }
            out.append(TrackedWindow(id: id, frame: frame, kind: kind))
        }
        return out
    }

    private var dockPID: pid_t = 0
    private var dockList: AXUIElement?

    /// Рамка значков Dock. Нужен доступ «Универсальный доступ»; без него — nil.
    /// Спрятанный Dock система держит за нижней кромкой экрана; во время анимации отдаёт
    /// промежуточные положения. Запрос ~0.3 мс, элемент списка кэшируется.
    func dockFrame() -> CGRect? {
        guard AXIsProcessTrusted() else { dockList = nil; return nil }
        if dockList == nil || NSRunningApplication(processIdentifier: dockPID)?.isTerminated != false {
            dockList = findDockList()
        }
        guard let el = dockList else { return nil }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else {
            dockList = nil         // Dock перезапустился — найдём заново в следующий раз
            return nil
        }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return s.width > 0 && s.height > 0 ? CGRect(origin: p, size: s) : nil
    }

    private func findDockList() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        dockPID = dock.processIdentifier
        let app = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for el in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if (role as? String) == (kAXListRole as String) {
                AXUIElementSetMessagingTimeout(el, 0.25)
                return el
            }
        }
        return nil
    }

    private func num(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }

    private func bundleID(_ pid: pid_t) -> String {
        if let b = bundles[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        bundles[pid] = b
        return b
    }
}
