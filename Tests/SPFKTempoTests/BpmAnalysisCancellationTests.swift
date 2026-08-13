// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKTempo

@Suite(.tags(.file))
struct BpmAnalysisCancellationTests {
    /// A user cancel and a genuine "no tempo found" both reach the same `guard` in `process()`,
    /// and `PlaylistProcessor` branches on the error type — reporting a cancel as an `NSError`
    /// surfaces it to the user as a failed file. Early termination cancels `processTask`
    /// internally without cancelling the enclosing task, so only the latter means a user cancel;
    /// the detection tests alongside this one cover that direction.
    @Test("a cancelled task throws CancellationError, not a detection failure")
    func cancellationIsNotADetectionFailure() async throws {
        let url = TestBundleResources.shared.tabla_wav

        let task = Task {
            try await BpmAnalysis(url: url).process()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
