// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation
import Testing

@testable import SPFKTempo

struct ACFCombFilterTests {
    /// A 120 BPM loop's autocorrelation at 100 hops per second over 12 s, the values measured on
    /// an eight-bar loop: the 48 BPM candidate's strongest term is its 10 s multiple, which
    /// overlaps only the first 2 s of the signal.
    @Test func shortOverlapTermDoesNotOutvoteTheBeat() {
        let hopsPerSec: Float = 100
        let frameCount = 1200
        var autocorrelation = [Float](repeating: 0, count: frameCount + 1)
        let terms: [(lag: Int, value: Float)] = [
            (50, 1.370), (200, 1.744), (400, 1.720), (800, 1.462), // 120 BPM ×1, 4, 8, 16
            (125, 1.345), (500, 1.655), (1000, 2.039), // 48 BPM ×1, 4, 8
        ]
        for term in terms {
            autocorrelation[term.lag] = term.value
        }

        let minLag = AutocorrelationFFT.bpmToLag(300, hopsPerSec: hopsPerSec)
        let maxLag = AutocorrelationFFT.bpmToLag(40, hopsPerSec: hopsPerSec)
        let comb = ACFCombFilter(beatsPerBar: 4, minLag: minLag, maxLag: maxLag, hopsPerSec: hopsPerSec)
        var filtered = [Float](repeating: 0, count: comb.filteredLength())
        comb.filter(
            autocorrelation: autocorrelation, autocorrelationLength: autocorrelation.count,
            frameCount: frameCount, filtered: &filtered
        )

        #expect(filtered[50 - minLag] > filtered[125 - minLag])
    }
}
