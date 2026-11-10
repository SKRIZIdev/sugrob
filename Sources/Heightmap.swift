/// Профиль снега вдоль горизонтальной кромки: высота в точках через каждые `cell` pt.
/// Снег оседает, осыпается по углу естественного откоса и ссыпается с краёв.
final class Heightmap {
    let cell: Float
    let maxH: Float
    private(set) var h: [Float]
    /// Профиль менялся и ещё не успокоился — нужен relax и перерисовка.
    private(set) var dirty = false

    init(width: Float, maxH: Float, cell: Float = 2.5) {
        self.cell = cell
        self.maxH = maxH
        h = Array(repeating: 0, count: Heightmap.count(width, cell))
    }

    private static func count(_ width: Float, _ cell: Float) -> Int {
        max(2, Int((max(width, 0) / cell).rounded(.up)) + 1)
    }

    var total: Float { h.reduce(0, +) * cell }

    /// Подогнать под новую ширину окна, растянув профиль.
    func resize(width: Float) {
        let n = Heightmap.count(width, cell)
        guard n != h.count else { return }
        let old = h, m = old.count
        var new = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / Float(n - 1) * Float(m - 1)
            let i0 = Int(t), i1 = min(i0 + 1, m - 1), f = t - Float(i0)
            new[i] = old[i0] * (1 - f) + old[i1] * f
        }
        h = new
        dirty = true
    }

    @inline(__always)
    func height(at x: Float) -> Float {
        let t = x / cell
        if !(t >= 0 && t <= Float(h.count - 1)) { return 0 }
        let i0 = Int(t), i1 = min(i0 + 1, h.count - 1), f = t - Float(i0)
        return h[i0] * (1 - f) + h[i1] * f
    }

    /// Положить снег площадью `area` pt² в точку x.
    func deposit(at x: Float, area: Float) {
        let i = Int((x / cell).rounded())
        let v = area / cell
        add(i, v * 0.5)
        add(i - 1, v * 0.25)
        add(i + 1, v * 0.25)
        dirty = true
    }

    @inline(__always)
    private func add(_ i: Int, _ v: Float) {
        guard i >= 0, i < h.count else { return }
        h[i] = min(maxH, h[i] + v)
    }

    /// Осыпание по углу откоса. Возвращает площадь снега, ссыпавшегося с левого и правого края.
    /// `edges: false` — края не ограничены (сугроб у кромки экрана).
    @discardableResult
    func relax(edges: Bool = true, slope: Float = 0.85) -> (left: Float, right: Float) {
        let lim = slope * cell
        let n = h.count
        var moved = false
        var i = 0
        while i < n - 1 {
            let d = h[i] - h[i + 1]
            if d > lim { let t = (d - lim) * 0.5; h[i] -= t; h[i + 1] += t; moved = true }
            else if d < -lim { let t = (-d - lim) * 0.5; h[i + 1] -= t; h[i] += t; moved = true }
            i += 1
        }
        i = n - 2
        while i >= 0 {
            let d = h[i] - h[i + 1]
            if d > lim { let t = (d - lim) * 0.5; h[i] -= t; h[i + 1] += t; moved = true }
            else if d < -lim { let t = (-d - lim) * 0.5; h[i + 1] -= t; h[i] += t; moved = true }
            i -= 1
        }
        var l: Float = 0, r: Float = 0
        if edges {
            if h[0] > lim { l = (h[0] - lim) * cell; h[0] = lim; moved = true }
            if h[n - 1] > lim { r = (h[n - 1] - lim) * cell; h[n - 1] = lim; moved = true }
        }
        dirty = moved
        return (l, r)
    }

    /// Снять долю снега в полосе x±halfWidth. Возвращает снятую площадь, pt².
    func carve(at x: Float, halfWidth: Float, fraction: Float) -> Float {
        let i0 = max(0, Int(((x - halfWidth) / cell).rounded(.down)))
        let i1 = min(h.count - 1, Int(((x + halfWidth) / cell).rounded(.up)))
        guard i0 <= i1, fraction > 0 else { return 0 }
        let f = min(fraction, 1)
        var taken: Float = 0
        for i in i0...i1 {
            let t = h[i] * f
            h[i] -= t
            taken += t
        }
        if taken > 0 { dirty = true }
        return taken * cell
    }

    /// Оставить долю `keep` снега по всей длине.
    func scale(_ keep: Float) {
        for i in h.indices { h[i] *= keep }
        dirty = true
    }

    func clear() {
        for i in h.indices { h[i] = 0 }
        dirty = false
    }
}
