// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation
import SPFKAudioBase
import SPFKTimePitchKernel
import Testing

/// The kernel clamps its rate to its own limits, so a description the model accepts but the kernel
/// clamps would render at a rate the edit does not say.
@Suite("TimePitchKernel rate range")
struct TimePitchKernelRateRangeTests {
    @Test func theKernelLimitsMatchTheDescriptionRange() {
        #expect(kTimePitchMinRate == TimePitchDescription.rateRange.lowerBound)
        #expect(kTimePitchMaxRate == TimePitchDescription.rateRange.upperBound)
    }
}
