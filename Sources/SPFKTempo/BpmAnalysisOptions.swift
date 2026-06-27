// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

/// Configuration for file-level BPM analysis.
///
/// Groups the analysis-level settings (chunking, looping, consensus) together
/// with the underlying ``BpmDetectionOptions`` that control the DSP algorithm.
///
/// ```swift
/// // Use defaults (matchesRequired: 3, tolerance: 1)
/// let bpm = try await BpmAnalysis(url: audioFileURL).process()
///
/// // Customize detection quality
/// let options = BpmAnalysisOptions(
///     detection: .init(quality: .accurate, bpmRange: 60 ... 200)
/// )
/// let bpm = try await BpmAnalysis(url: audioFileURL, options: options).process()
/// ```
public struct BpmAnalysisOptions: Sendable {
    /// Duration in seconds of each analysis chunk fed to the detection engine.
    /// Larger values reduce overhead but increase latency before the first estimate.
    public var bufferDuration: TimeInterval

    /// Files shorter than half this value are looped in-memory to provide enough
    /// material for detection. Pass `nil` to disable looping.
    public var minimumDuration: TimeInterval?

    /// Number of consistent periodic estimates needed to stop early.
    /// With the default periodic interval of 4 seconds, 3 matches means
    /// at least ~12 seconds of audio before early exit is possible.
    /// Pass `nil` to process the entire file.
    public var matchesRequired: Int?

    /// BPM tolerance for consensus matching. When greater than zero,
    /// two estimates within this range are considered equivalent.
    /// A tolerance of 1 accommodates the ±1 BPM jitter inherent in
    /// autocorrelation lag quantization.
    public var tolerance: Double

    /// Detection algorithm options (quality, BPM range, etc.).
    public var detection: BpmDetectionOptions

    /// Preferred BPM range for post-processing octave correction.
    ///
    /// After the detection engine produces an estimate, the result is octave-shifted
    /// (×2 or ÷2) until it falls within this range. This corrects common half-tempo
    /// and double-tempo errors without constraining the underlying detection algorithm.
    /// Pass `nil` to disable octave correction.
    public var preferredRange: ClosedRange<Float>?

    /// Number of decimal places to retain in the output BPM value (0–3).
    ///
    /// `0` returns integer BPM (e.g. 120), `1` retains one decimal place (e.g. 120.5),
    /// and so on. Values outside 0–3 are clamped.
    public var outputDecimalPlaces: Int

    public init(
        bufferDuration: TimeInterval = 1,
        minimumDuration: TimeInterval? = 15,
        matchesRequired: Int? = 3,
        tolerance: Double = 1,
        detection: BpmDetectionOptions = .init(),
        preferredRange: ClosedRange<Float>? = 60 ... 200,
        outputDecimalPlaces: Int = 0
    ) {
        self.bufferDuration = bufferDuration
        self.minimumDuration = minimumDuration
        self.matchesRequired = matchesRequired
        self.tolerance = tolerance
        self.detection = detection
        self.preferredRange = preferredRange
        self.outputDecimalPlaces = outputDecimalPlaces.clamped(to: 0 ... 3)
    }
}
