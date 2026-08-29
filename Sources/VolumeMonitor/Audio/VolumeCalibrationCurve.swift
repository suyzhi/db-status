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
        if x <= first.volume { return first.relativeDB }
        if x >= last.volume { return last.relativeDB }
        if x == first.volume { return first.relativeDB }
        for (left, right) in zip(points, points.dropFirst()) where x <= right.volume {
            return interpolate(x: x, left: left, right: right)
        }
        return last.relativeDB
    }

    func relativeDB(
        at volume: Float,
        alignedToOriginalModel originalModelDB: (Float) -> Double
    ) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let x = min(max(volume, 0), 1)
        if x < first.volume {
            return alignedModelValue(x: x, edge: first, originalModelDB: originalModelDB)
        }
        if x > last.volume {
            return alignedModelValue(x: x, edge: last, originalModelDB: originalModelDB)
        }
        return relativeDB(at: x)
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

    private func alignedModelValue(
        x: Float,
        edge: (volume: Float, relativeDB: Double),
        originalModelDB: (Float) -> Double
    ) -> Double {
        let currentModel = originalModelDB(x)
        let edgeModel = originalModelDB(edge.volume)
        guard currentModel.isFinite, edgeModel.isFinite else { return edge.relativeDB }
        return edge.relativeDB + currentModel - edgeModel
    }
}
