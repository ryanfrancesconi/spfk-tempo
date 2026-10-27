// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation
import SPFKAudioBase

/// Collects the periodic tempo estimates of one file and says when enough agree.
///
/// Each estimate covers everything processed so far, so the latest is the best informed and is
/// the decision; the earlier ones only serve the stopping rule. Votes group into octave families
/// (``Bpm/isMultiple(of:tolerance:)-1o201``), and the scan may end once a family holds
/// `matchesRequired` votes. A `nil` vote says no tempo was present so far and never ends the scan.
struct TempoVoteTally {
    private let matchesRequired: Int?
    private let tolerance: Double
    private var votes: [Bpm?] = []
    private var families: [(representative: Bpm, count: Int)] = []

    init(matchesRequired: Int?, tolerance: Double) {
        self.matchesRequired = matchesRequired
        self.tolerance = max(0, tolerance)
    }

    var isEmpty: Bool { votes.isEmpty }

    /// Records a vote, returning true once a family holds `matchesRequired` votes.
    mutating func append(_ vote: Bpm?) -> Bool {
        votes.append(vote)
        guard let vote else { return false }

        let count: Int
        if let index = families.firstIndex(where: { sameFamily($0.representative, vote) }) {
            families[index].count += 1
            count = families[index].count
        } else {
            families.append((vote, 1))
            count = 1
        }

        if let matchesRequired, count >= matchesRequired { return true }
        return false
    }

    /// The latest vote; nil when it found no tempo, or when there are none.
    var decision: Bpm? {
        votes.last ?? nil
    }

    private func sameFamily(_ a: Bpm, _ b: Bpm) -> Bool {
        tolerance > 0 ? a.isMultiple(of: b, tolerance: tolerance) : a == b
    }
}
