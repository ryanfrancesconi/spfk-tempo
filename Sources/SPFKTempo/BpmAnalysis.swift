// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase

/// Detects the tempo (BPM) of an audio file using multi-band spectral analysis.
///
/// `BpmAnalysis` streams audio through an ``AudioFileScanner``, feeding chunks
/// to a ``BpmDetection`` engine that performs multi-band onset detection and
/// autocorrelation-based tempo estimation. Periodic estimates are compared via
/// consensus voting (``CountableResult``), and processing stops early once
/// enough consistent estimates have been collected.
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
    private var results: CountableResult<Bpm?>
    private let eventHandler: URLProgressEventHandler?

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

        if options.tolerance > 0 {
            results = CountableResult(matchesRequired: options.matchesRequired) { a, b in
                switch (a, b) {
                case (nil, nil): true
                case let (a?, b?): a.isMultiple(of: b, tolerance: options.tolerance)
                default: false
                }
            }
        } else {
            results = CountableResult(matchesRequired: options.matchesRequired)
        }

        bpmDetection = BpmDetection(
            sampleRate: audioFile.processingFormat.sampleRate.float,
            options: options.detection
        )
    }

    /// Runs the BPM analysis and returns the detected tempo.
    ///
    /// Streams the audio file through the detection engine, periodically estimating
    /// tempo and collecting results for consensus voting. If `matchesRequired` was set,
    /// processing stops early once enough consistent estimates are collected —
    /// including when enough estimates agree that no tempo is present.
    ///
    /// - Returns: The detected tempo as a ``Bpm`` value, or `nil` if the consensus
    ///   determined no rhythmic content was found.
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

        guard let bpm = results.choose() else {
            throw NSError(description: "Failed to detect bpm")
        }

        return bpm
    }

    private func analyze(_ event: AudioFileScannerEvent) async {
        switch event {
        case let .progress(url: url, value: value):
            await eventHandler?(.progress(url: url, value: value))

        case .periodicProgress:
            let value = bpmDetection.estimateTempo().rounded(.toNearestOrAwayFromZero)

            Log.debug("periodicProgress", value)

            let bpm = Bpm(value)

            if results.append(bpm) {
                processTask?.cancel()

                Log.debug("periodicProgress met matches required:", value)
            }

        case .data(format: _, length: let length, samples: let samples):
            bpmDetection.process(samples.pointee, count: Int(length))

        case .complete:
            // Final estimation with all accumulated data
            let value = bpmDetection.estimateTempo().rounded(.toNearestOrAwayFromZero)
            _ = results.append(Bpm(value))
        }
    }
}
