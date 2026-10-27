// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation
import SPFKAudioBase

/// Collects the periodic tempo estimates of one file and decides between them.
///
/// Votes group into families by octave (``Bpm/isMultiple(of:tolerance:)-1o201``); the family
/// with the most votes wins, and within it the most common value, the latest on a tie. A `nil`
/// vote says no tempo was present so far and never counts toward early termination.
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

    /// The winning family's most common value; nil when no vote found a tempo.
    var decision: Bpm? {
        guard let family = families.max(by: { $0.count < $1.count })?.representative else { return nil }

        var counts: [(value: Bpm, count: Int, latest: Int)] = []
        for (index, vote) in votes.enumerated() {
            guard let vote, sameFamily(vote, family) else { continue }
            if let at = counts.firstIndex(where: { $0.value == vote }) {
                counts[at].count += 1
                counts[at].latest = index
            } else {
                counts.append((vote, 1, index))
            }
        }

        return counts.max { a, b in a.count < b.count || (a.count == b.count && a.latest < b.latest) }?.value
    }

    private func sameFamily(_ a: Bpm, _ b: Bpm) -> Bool {
        tolerance > 0 ? a.isMultiple(of: b, tolerance: tolerance) : a == b
    }
}
