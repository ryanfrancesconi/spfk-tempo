import Foundation
import SPFKAudioBase
import Testing

@testable import SPFKTempo

@Suite("TempoVoteTally")
struct TempoVoteTallyTests {
    private func bpm(_ value: Double) -> Bpm? { Bpm(value) }

    /// Appends outside the expectation macro, which would capture the tally as a value.
    private func cast(_ vote: Bpm?, on tally: inout TempoVoteTally) -> Bool {
        tally.append(vote)
    }

    @Test("Votes without a tempo never reach the match count")
    func nilVotesDoNotTerminate() {
        var tally = TempoVoteTally(matchesRequired: 3, tolerance: 1)
        #expect(!cast(nil, on: &tally))
        #expect(!cast(nil, on: &tally))
        #expect(!cast(nil, on: &tally))
        #expect(tally.decision == nil)
        #expect(!cast(bpm(120), on: &tally))
        #expect(!cast(bpm(120), on: &tally))
        #expect(cast(bpm(120), on: &tally))
        #expect(tally.decision == bpm(120))
    }

    @Test("Octaves count toward one family's match count")
    func octavesShareAFamily() {
        var tally = TempoVoteTally(matchesRequired: 3, tolerance: 1)
        #expect(!cast(bpm(120), on: &tally))
        #expect(!cast(bpm(240), on: &tally))
        #expect(cast(bpm(60), on: &tally))
    }

    @Test("The latest vote decides, including a late no-tempo vote")
    func latestVoteDecides() {
        var tally = TempoVoteTally(matchesRequired: nil, tolerance: 1)
        for value in [100.0, 140, 140] { _ = tally.append(bpm(value)) }
        #expect(tally.decision == bpm(140))
        _ = tally.append(nil)
        #expect(tally.decision == nil)
    }

    @Test("Tolerance groups neighboring values into one family")
    func toleranceGroupsNeighbors() {
        var tally = TempoVoteTally(matchesRequired: 2, tolerance: 1)
        #expect(!cast(bpm(120), on: &tally))
        #expect(cast(bpm(120.8), on: &tally))
    }
}
