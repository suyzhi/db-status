import Testing
@testable import VolumeMonitor

@Suite struct ExposureMathTests {
    @Test func adultEightyDBAForFortyHoursIsFullDose() {
        let energy = ExposureMath.normalizedEnergyAt80(
            levelDBA: 80,
            duration: 40 * 60 * 60
        )
        #expect(abs(ExposureMath.doseFraction(normalizedEnergyAt80: energy, mode: .adult) - 1) <= 0.000_001)
    }

    @Test func adultEightyThreeDBAForTwentyHoursIsFullDose() {
        let energy = ExposureMath.normalizedEnergyAt80(
            levelDBA: 83,
            duration: 20 * 60 * 60
        )
        #expect(abs(ExposureMath.doseFraction(normalizedEnergyAt80: energy, mode: .adult) - 1) <= 0.003)
    }

    @Test func conservativeSeventyFiveDBAForFortyHoursIsFullDose() {
        let energy = ExposureMath.normalizedEnergyAt80(
            levelDBA: 75,
            duration: 40 * 60 * 60
        )
        #expect(abs(ExposureMath.doseFraction(normalizedEnergyAt80: energy, mode: .conservative) - 1) <= 0.000_001)
    }

    @Test func remainingTimeMatchesReference() throws {
        let remaining = try #require(ExposureMath.remainingTime(
            levelDBA: 80,
            currentDose: 0,
            mode: .adult
        ))
        #expect(abs(remaining - 40 * 60 * 60) <= 0.001)
    }
}
