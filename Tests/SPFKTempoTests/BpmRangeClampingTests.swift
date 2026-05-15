import Foundation
import SPFKAudioBase
import SPFKBase
import Testing

@testable import SPFKTempo

@Suite("BPM range clamping")
struct BpmRangeClampingTests {
    let range: ClosedRange<Float> = 60 ... 120

    @Test("Value already in range is returned unchanged")
    func inRange() {
        let result = Bpm(90)?.clamped(to: range)
        #expect(result?.rawValue == 90)
    }

    @Test("Value below range is doubled into range")
    func doubledIntoRange() {
        // 45 * 2 = 90, which is within 60-120
        let result = Bpm(45)?.clamped(to: range)
        #expect(result?.rawValue == 90)
    }

    @Test("Value requires multiple doublings to enter range")
    func multipleDoublings() {
        // 22.5 * 2 = 45, * 2 = 90
        let result = Bpm(22.5)?.clamped(to: range)
        #expect(result?.rawValue == 90)
    }

    @Test("Value above range is halved into range")
    func halvedIntoRange() {
        // 240 / 2 = 120, which is within 60-120
        let result = Bpm(240)?.clamped(to: range)
        #expect(result?.rawValue == 120)
    }

    @Test("Value requires multiple halvings to enter range")
    func multipleHalvings() {
        // 480 / 2 = 240, / 2 = 120
        let result = Bpm(480)?.clamped(to: range)
        #expect(result?.rawValue == 120)
    }

    @Test("Value that cannot be brought into range returns nil")
    func cannotClamp() {
        // 45 * 2 = 90 > 80, can't clamp into 70-80
        let result = Bpm(45)?.clamped(to: 70 ... 80)
        #expect(result == nil)
    }
}
