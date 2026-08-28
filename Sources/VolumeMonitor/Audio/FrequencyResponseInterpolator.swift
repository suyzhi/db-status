import Foundation

struct FrequencyResponseInterpolator: Sendable {
    private let points: [(logFrequency: Double, responseDB: Double)]

    init?(points: [FrequencyCalibrationPoint]) {
        let sorted = points.sorted { $0.frequencyHz < $1.frequencyHz }
        guard sorted.count >= 2,
              sorted.allSatisfy({
                  $0.frequencyHz.isFinite && $0.frequencyHz > 0 && $0.relativeDB.isFinite
              }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.frequencyHz < $1.frequencyHz }) else {
            return nil
        }
        self.points = sorted.map { (log($0.frequencyHz), $0.relativeDB) }
    }

    func responseDB(at frequencyHz: Double) -> Double {
        guard frequencyHz.isFinite, frequencyHz > 0,
              let first = points.first, let last = points.last else { return 0 }
        let x = log(frequencyHz)
        if x <= first.logFrequency { return first.responseDB }
        if x >= last.logFrequency { return last.responseDB }
        for (left, right) in zip(points, points.dropFirst()) where x <= right.logFrequency {
            let width = right.logFrequency - left.logFrequency
            guard width > 0 else { return right.responseDB }
            let fraction = (x - left.logFrequency) / width
            return left.responseDB + (right.responseDB - left.responseDB) * fraction
        }
        return last.responseDB
    }
}
