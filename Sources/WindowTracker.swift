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

    /// Окна, на которые может лечь снег, спереди назад.
    func poll() -> [TrackedWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [TrackedWindow] = []
        out.reserveCapacity(48)
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

    /// Рамка значков Dock. Нужен доступ «Универсальный доступ»; без него — nil.
    func dockFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for el in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == (kAXListRole as String) else { continue }
            var pv: CFTypeRef?, sv: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
                  let pv, let sv,
                  CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            if s.width > 0, s.height > 0 { return CGRect(origin: p, size: s) }
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
