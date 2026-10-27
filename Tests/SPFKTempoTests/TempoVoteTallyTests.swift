import Foundation
import SPFKAudioBase
import Testing

@testable import SPFKTempo

@Suite("TempoVoteTally")
struct TempoVoteTallyTests {
    private func bpm(_ value: Double) -> Bpm? { Bpm(value) }

    /// Appends and returns whether the match count was reached, outside the macro so the
    /// mutation is not captured as a value.
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

    @Test("Octaves share a family and the family's most common octave is returned")
    func octaveByCountWithinFamily() {
        var tally = TempoVoteTally(matchesRequired: 3, tolerance: 1)
        #expect(!cast(bpm(120), on: &tally))
        #expect(!cast(bpm(120), on: &tally))
        #expect(cast(bpm(60), on: &tally))
        #expect(tally.decision == bpm(120))
    }

    @Test("The family with more votes wins")
    func familyByCount() {
        var tally = TempoVoteTally(matchesRequired: nil, tolerance: 1)
        for value in [100.0, 140, 140, 100, 100] { _ = tally.append(bpm(value)) }
        #expect(tally.decision == bpm(100))
    }

    @Test("A tie within the family goes to the latest vote")
    func tieGoesToLatest() {
        var tally = TempoVoteTally(matchesRequired: nil, tolerance: 1)
        for value in [120.0, 240, 60] { _ = tally.append(bpm(value)) }
        #expect(tally.decision == bpm(60))
    }

    @Test("Tolerance groups neighboring values into one family")
    func toleranceGroupsNeighbors() {
        var tally = TempoVoteTally(matchesRequired: 2, tolerance: 1)
        #expect(!cast(bpm(120), on: &tally))
        #expect(cast(bpm(120.8), on: &tally))
    }
}
