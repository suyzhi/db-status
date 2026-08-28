import Foundation

struct VolumeCalibrationCurve: Sendable {
    private let points: [(volume: Float, relativeDB: Double)]

    init?(points: [VolumeCalibrationPoint]) {
        let sorted = points.sorted { $0.systemVolume < $1.systemVolume }
        guard sorted.count >= 2,
              sorted.allSatisfy({
                  $0.systemVolume.isFinite && (0...1).contains($0.systemVolume) &&
                  $0.relativeDB.isFinite
              }),
              zip(sorted, sorted.dropFirst()).allSatisfy({
                  $0.systemVolume < $1.systemVolume && $0.relativeDB <= $1.relativeDB
              }) else { return nil }
        self.points = sorted.map { ($0.systemVolume, $0.relativeDB) }
    }

    func relativeDB(at volume: Float) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let x = min(max(volume, 0), 1)
        if x < first.volume {
            return boundedExtrapolation(x: x, edge: first, neighbor: points[1])
        }
        if x > last.volume {
            return boundedExtrapolation(x: x, edge: last, neighbor: points[points.count - 2])
        }
        if x == first.volume { return first.relativeDB }
        for (left, right) in zip(points, points.dropFirst()) where x <= right.volume {
            return interpolate(x: x, left: left, right: right)
        }
        return last.relativeDB
    }

    private func interpolate(
        x: Float,
        left: (volume: Float, relativeDB: Double),
        right: (volume: Float, relativeDB: Double)
    ) -> Double {
        let width = Double(right.volume - left.volume)
        guard width > 0 else { return right.relativeDB }
        let fraction = Double(x - left.volume) / width
        return left.relativeDB + (right.relativeDB - left.relativeDB) * fraction
    }

    private func boundedExtrapolation(
        x: Float,
        edge: (volume: Float, relativeDB: Double),
        neighbor: (volume: Float, relativeDB: Double)
    ) -> Double {
        let width = Double(edge.volume - neighbor.volume)
        guard abs(width) > .ulpOfOne else { return edge.relativeDB }
        let slope = (edge.relativeDB - neighbor.relativeDB) / width
        let extrapolated = edge.relativeDB + slope * Double(x - edge.volume)
        let limitedAroundEdge = min(max(extrapolated, edge.relativeDB - 24), edge.relativeDB + 24)
        return min(max(limitedAroundEdge, -80), 24)
    }
}
