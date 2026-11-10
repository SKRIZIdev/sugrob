import Foundation

/// Профиль снега вдоль горизонтальной кромки: высота в точках через каждые `cell` pt.
/// Снег оседает, осыпается по углу естественного откоса и ссыпается с краёв.
final class Heightmap {
    let cell: Float
    let maxH: Float
    /// На этом расстоянии от концов предел высоты сходит на нет по дуге — сугроб на скруглённых
    /// углах окна или Dock не обрывается стенкой и не свисает.
    let endRadius: Float
    private(set) var h: [Float]
    /// Предел высоты по ячейкам: волнистый, чтобы полный сугроб не выглядел ровной плитой.
    private var limit: [Float] = []
    private let phase: (Float, Float) = (Float.random(in: 0...6.28), Float.random(in: 0...6.28))
    /// Профиль менялся и ещё не успокоился — нужен relax и перерисовка.
    private(set) var dirty = false

    init(width: Float, maxH: Float, cell: Float = 2.5, endRadius: Float = 0) {
        self.cell = cell
        self.maxH = maxH
        self.endRadius = endRadius
        h = Array(repeating: 0, count: Heightmap.count(width, cell))
        makeLimit()
    }

    private static func count(_ width: Float, _ cell: Float) -> Int {
        max(2, Int((max(width, 0) / cell).rounded(.up)) + 1)
    }

    private func makeLimit() {
        var l = [Float](repeating: maxH, count: h.count)
        let last = Float(h.count - 1) * cell
        for i in l.indices {
            let x = Float(i) * cell
            let slow: Float = sin(x / 37 + phase.0)
            let fast: Float = sin(x / 13 + phase.1)
            l[i] = maxH * (0.84 + 0.08 * (slow + fast))      // ±16% вокруг 84% от потолка
            let d = min(x, last - x)
            if endRadius > 0, d < endRadius {                // четверть окружности к концам
                let u = 1 - d / endRadius
                l[i] *= (1 - u * u).squareRoot()
            }
        }
        limit = l
    }

    var total: Float { h.reduce(0, +) * cell }
    var width: Float { Float(h.count - 1) * cell }

    /// Переложить снег из `other` сюда: ячейка j забирает снег из точки `j·cell + offset` профиля
    /// `other` (в его координатах), а там снег обнуляется. Сверх предела высоты — теряется.
    /// Возвращает площадь, не поместившуюся у левого и правого конца (она осыпается).
    @discardableResult
    func absorb(_ other: Heightmap, offset: Float) -> (left: Float, right: Float) {
        var l: Float = 0, r: Float = 0
        for j in h.indices {
            let v = other.height(at: Float(j) * cell + offset)
            guard v > 0 else { continue }
            let sum = h[j] + v
            h[j] = min(limit[j], sum)
            let extra = (sum - h[j]) * cell
            if j < h.count / 2 { l += extra } else { r += extra }
        }
        other.zero(from: offset, to: offset + width)
        dirty = true
        return (l, r)
    }

    func copy() -> Heightmap {
        let m = Heightmap(width: width, maxH: maxH, cell: cell, endRadius: endRadius)
        m.h = h
        m.limit = limit
        return m
    }

    /// Обнулить снег на отрезке [a, b] (в координатах профиля).
    func zero(from a: Float, to b: Float) {
        let i0 = max(0, Int((a / cell).rounded(.up)))
        let i1 = min(h.count - 1, Int((b / cell).rounded(.down)))
        guard i0 <= i1 else { return }
        for i in i0...i1 { h[i] = 0 }
        dirty = true
    }

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
        makeLimit()
        dirty = true
    }

    /// Высота для отрисовки: сглаженная по соседям, чтобы плечи сугроба были круглыми, а не зубчатыми.
    @inline(__always)
    func smooth(_ i: Int) -> Float {
        let n = h.count
        let a = h[max(i - 2, 0)], b = h[max(i - 1, 0)], c = h[i], d = h[min(i + 1, n - 1)], e = h[min(i + 2, n - 1)]
        return (a + 2 * b + 3 * c + 2 * d + e) / 9
    }

    @inline(__always)
    func height(at x: Float) -> Float {
        let t = x / cell
        if !(t >= 0 && t <= Float(h.count - 1)) { return 0 }
        let i0 = Int(t), i1 = min(i0 + 1, h.count - 1), f = t - Float(i0)
        return h[i0] * (1 - f) + h[i1] * f
    }

    /// Положить снег площадью `area` pt² в точку x.
    /// Снежинка ложится не в одну ячейку, а пятном на пять — так сугроб растёт ровно, без пиков.
    func deposit(at x: Float, area: Float) {
        let i = Int((x / cell).rounded())
        let v = area / cell
        add(i, v * 0.36)
        add(i - 1, v * 0.22)
        add(i + 1, v * 0.22)
        add(i - 2, v * 0.10)
        add(i + 2, v * 0.10)
        dirty = true
    }

    @inline(__always)
    private func add(_ i: Int, _ v: Float) {
        guard i >= 0, i < h.count else { return }
        h[i] = min(limit[i], h[i] + v)
    }

    /// Осыпание по углу откоса. Возвращает площадь снега, ссыпавшегося с левого и правого края.
    /// `edges: false` — края не ограничены (сугроб у кромки экрана).
    @discardableResult
    func relax(edges: Bool = true, slope: Float = 0.6) -> (left: Float, right: Float) {
        let lim = slope * cell
        let eps: Float = 0.002          // мельче — не считаем движением, иначе профиль «дрожит» вечно
        let n = h.count
        var moved = false
        var i = 0
        while i < n - 1 {
            let d = h[i] - h[i + 1]
            if d > lim + eps { let t = (d - lim) * 0.5; h[i] -= t; h[i + 1] += t; moved = true }
            else if d < -lim - eps { let t = (-d - lim) * 0.5; h[i + 1] -= t; h[i] += t; moved = true }
            i += 1
        }
        i = n - 2
        while i >= 0 {
            let d = h[i] - h[i + 1]
            if d > lim + eps { let t = (d - lim) * 0.5; h[i] -= t; h[i + 1] += t; moved = true }
            else if d < -lim - eps { let t = (-d - lim) * 0.5; h[i + 1] -= t; h[i] += t; moved = true }
            i -= 1
        }
        var l: Float = 0, r: Float = 0
        if endRadius > 0 {
            for i in h.indices where h[i] > limit[i] + eps {
                let extra = (h[i] - limit[i]) * cell
                h[i] = limit[i]
                if i < n / 2 { l += extra } else { r += extra }
                moved = true
            }
        }
        if edges {
            if h[0] > lim + eps { l = (h[0] - lim) * cell; h[0] = lim; moved = true }
            if h[n - 1] > lim + eps { r = (h[n - 1] - lim) * cell; h[n - 1] = lim; moved = true }
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
