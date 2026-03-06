import Foundation
import Testing

@testable import SPFKTempo

@Suite("BpmAnalysisOptions")
struct BpmAnalysisOptionsTests {
    @Test("Defaults are sane")
    func defaults() {
        let options = BpmAnalysisOptions()

        #expect(options.bufferDuration == 1.0)
        #expect(options.minimumDuration == 15)
        #expect(options.matchesRequired == 3)
        #expect(options.tolerance == 1)
        #expect(options.detection.quality == .balanced)
        #expect(options.detection.bpmRange == 40 ... 300)
        #expect(options.detection.confidenceLevel == .moderate)
    }

    @Test("Custom values are stored correctly")
    func customValues() {
        let options = BpmAnalysisOptions(
            bufferDuration: 2.0,
            minimumDuration: 30,
            matchesRequired: 5,
            tolerance: 1.5,
            detection: .init(quality: .accurate, bpmRange: 60 ... 200)
        )

        #expect(options.bufferDuration == 2.0)
        #expect(options.minimumDuration == 30)
        #expect(options.matchesRequired == 5)
        #expect(options.tolerance == 1.5)
        #expect(options.detection.quality == .accurate)
        #expect(options.detection.bpmRange == 60 ... 200)
    }

    @Test("Nil minimumDuration disables looping")
    func nilMinimumDuration() {
        let options = BpmAnalysisOptions(minimumDuration: nil)
        #expect(options.minimumDuration == nil)
    }
}
