// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase

/// Detects the tempo (BPM) of an audio file using multi-band spectral analysis.
///
/// `BpmAnalysis` streams audio through an ``AudioFileScanner``, feeding chunks
/// to a ``BpmDetection`` engine that performs multi-band onset detection and
/// autocorrelation-based tempo estimation. Each periodic estimate covers all
/// audio so far; processing stops early once enough agree on an octave family,
/// and the latest estimate is the result.
///
/// Short files are automatically looped in-memory when shorter than half the
/// `minimumDuration`, ensuring enough material for reliable tempo detection.
///
/// ```swift
/// let bpm = try await BpmAnalysis(url: audioFileURL).process()
/// ```
public actor BpmAnalysis: Sendable {
    private let bufferDuration: TimeInterval
    private let minimumDuration: TimeInterval?
    private var bpmDetection: BpmDetection
    private let audioFile: AVAudioFile
    private var results: TempoVoteTally
    private let eventHandler: URLProgressEventHandler?
    private let preferredRange: ClosedRange<Float>?
    private let outputDecimalPlaces: Int

    /// The file's own length when the scanner loops it, so a vote can check the file repeats
    /// inside itself; nil when the file is read once.
    private let loopedDuration: TimeInterval?
    private var loopedSelfSimilarity: Float?

    var processTask: Task<Void, Error>?

    /// Creates a BPM analyzer for the audio file at `url`.
    ///
    /// - Parameters:
    ///   - url: A file URL for any audio format supported by Core Audio.
    ///   - options: Analysis and detection options.
    ///   - eventHandler: Optional callback for progress and completion events.
    /// - Throws: If the audio file cannot be opened.
    public init(
        url: URL,
        options: BpmAnalysisOptions = .init(),
        eventHandler: URLProgressEventHandler? = nil
    ) throws {
        let audioFile = try AVAudioFile(forReading: url)

        self.init(
            audioFile: audioFile,
            options: options,
            eventHandler: eventHandler
        )
    }

    /// Creates a BPM analyzer for an already-opened audio file.
    ///
    /// - Parameters:
    ///   - audioFile: An open `AVAudioFile` to analyze.
    ///   - options: Analysis and detection options.
    ///   - eventHandler: Optional callback for progress and completion events.
    public init(
        audioFile: AVAudioFile,
        options: BpmAnalysisOptions = .init(),
        eventHandler: URLProgressEventHandler? = nil
    ) {
        bufferDuration = max(0.1, options.bufferDuration)
        minimumDuration = options.minimumDuration
        self.eventHandler = eventHandler
        self.audioFile = audioFile

        results = TempoVoteTally(matchesRequired: options.matchesRequired, tolerance: options.tolerance)
        preferredRange = options.preferredRange
        outputDecimalPlaces = options.outputDecimalPlaces

        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        loopedDuration = options.minimumDuration.flatMap { duration > 0 && duration * 2 < $0 ? duration : nil }

        bpmDetection = BpmDetection(
            sampleRate: audioFile.processingFormat.sampleRate.float,
            options: options.detection
        )
    }

    /// Runs the BPM analysis and returns the detected tempo.
    ///
    /// Streams the audio file through the detection engine, periodically estimating
    /// tempo. If `matchesRequired` was set, processing stops early once that many
    /// estimates agree on an octave family; estimates finding no tempo never end it.
    ///
    /// - Returns: The detected tempo as a ``Bpm`` value, or `nil` if the latest
    ///   estimate found no rhythmic content.
    /// - Throws: If the analysis produced no results at all.
    public func process() async throws -> Bpm? {
        processTask = Task<Void, Error> {
            let audioAnalysis = AudioFileScanner(
                bufferDuration: bufferDuration,
                sendPeriodicProgressEvery: 4,
                minimumDuration: minimumDuration,
                eventHandler: analyze(_:)
            )

            try await audioAnalysis.process(audioFile: audioFile)

            await eventHandler?(
                .complete(url: audioFile.url)
            )
        }

        // Bridge cancellation from the calling structured context into the
        // unstructured processTask. Without this, cancelling the parent task
        // (e.g. via a task group) won't reach AudioFileScanner's loop.
        // Capture the task locally so the @Sendable onCancel closure doesn't
        // need actor-isolated access.
        let task = processTask
        _ = await withTaskCancellationHandler {
            await task?.result
        } onCancel: {
            task?.cancel()
        }

        // Read from the enclosing task, not `processTask` — that one is also cancelled by
        // `analyze(_:)` for early termination, which is not a user cancel.
        try Task.checkCancellation()

        guard !results.isEmpty else {
            throw NSError(description: "Failed to detect bpm")
        }

        return results.decision
    }

    private func octaveCorrected(_ bpm: Bpm?) -> Bpm? {
        guard let bpm, let range = preferredRange else { return bpm }
        return bpm.clamped(to: range)
    }

    /// When `raw` is suspiciously slow (< 60 BPM) and a 4× or 2× multiple of
    /// `raw` appears in the top candidates, returns that faster multiple.
    /// Checked in 4× → 2× order so a quarter-tempo sub-harmonic (e.g. 50 for a
    /// 200 BPM file) promotes all the way to the correct fundamental, not just
    /// half-tempo.
    private func preferFasterMultipleIfCandidateExists(_ raw: Double) -> Double {
        guard raw < 60 else { return raw }
        let cap = preferredRange.map { Double($0.upperBound) } ?? 300.0
        let candidates = bpmDetection.tempoCandidates
        for multiplier in [4.0, 2.0] {
            let faster = raw * multiplier
            if faster > cap { continue }
            if let idx = candidates.firstIndex(where: { abs($0 - faster) <= 5.0 }), idx <= 3 {
                return faster
            }
        }
        return raw
    }

    /// Doubles `raw` when it rounds to exactly X.5 at one decimal place — the
    /// specific signature of a half-tempo sub-harmonic detection (e.g. 62.48 → 124.96).
    /// Does not apply rounding; the caller applies decimal-place rounding after this.
    private func applyHalfTempoCorrection(_ raw: Double) -> Double {
        let tenths = Int((raw * 10).rounded(.toNearestOrAwayFromZero))
        guard tenths % 10 == 5 else { return raw }
        let doubled = raw * 2
        let cap = preferredRange.map { Double($0.upperBound) } ?? 300
        guard doubled <= cap else { return raw }
        return doubled
    }

    /// Whether a looped file has been shown to repeat inside its own length. Nil until enough
    /// audio has been processed to tell; true for a file that is not looped.
    private func loopedFileRepeats() -> Bool? {
        guard let loopedDuration else { return true }
        if loopedSelfSimilarity == nil {
            loopedSelfSimilarity = bpmDetection.selfSimilarity(within: loopedDuration)
        }
        guard let loopedSelfSimilarity else { return nil }
        return loopedSelfSimilarity >= Self.loopedSelfSimilarityFloor
    }

    /// Below this, a looped file's only period is its own length. One-shots measure about 0.02,
    /// a short tabla phrase 0.21, vendor loops 0.26 and up.
    static let loopedSelfSimilarityFloor: Float = 0.1

    /// One vote from everything processed so far; nil when no tempo is present.
    private func vote() -> Bpm? {
        let raw = bpmDetection.estimateTempo()
        let adjusted = preferFasterMultipleIfCandidateExists(raw)
        let corrected = applyHalfTempoCorrection(adjusted)
        return octaveCorrected(Bpm(corrected))?.rounded(to: outputDecimalPlaces)
    }

    private func analyze(_ event: AudioFileScannerEvent) async {
        switch event {
        case let .progress(url: url, value: value):
            await eventHandler?(.progress(url: url, value: value))

        case .periodicProgress:
            guard let repeats = loopedFileRepeats() else { return }

            if results.append(repeats ? vote() : nil) {
                processTask?.cancel()
            }

        case .data(format: _, length: let length, samples: let samples):
            bpmDetection.process(samples.pointee, count: Int(length))

        case .complete:
            let repeats = loopedFileRepeats() ?? false
            _ = results.append(repeats ? vote() : nil)
        }
    }
}

