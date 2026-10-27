// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

/// Controls how aggressively the detector rejects non-rhythmic audio.
///
/// The detector compares the comb response's peak against its median over the
/// tempo range. Noise and drones measure 1.03–1.07; rhythmic material 1.5 and
/// up, with sparse pads and chord beds between. Higher thresholds reject more.
public enum ConfidenceLevel: Sendable {
    /// Accept any result that produces peaks, even for noise-like audio.
    case disabled
    /// Reject only clearly non-rhythmic signals (threshold 1.05).
    case low
    /// Balanced rejection of non-rhythmic content (threshold 1.1).
    case moderate
    /// Aggressively reject ambiguous results (threshold 1.3).
    case high

    var threshold: Float {
        switch self {
        case .disabled: 0
        case .low: 1.05
        case .moderate: 1.1
        case .high: 1.3
        }
    }
}
