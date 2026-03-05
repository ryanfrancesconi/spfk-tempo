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
    private let eventHandler: URLProgressEventHandler?
    private var bpmDetection: BpmDetection
    private let audioFile: AVAudioFile
    private var results: CountableResult<Bpm>

    var processTask: Task<Void, Error>?

    /// Creates a BPM analyzer for the audio file at `url`.
    ///
    /// - Parameters:
    ///   - url: A file URL for any audio format supported by Core Audio.
    ///   - bufferDuration: Duration in seconds of each analysis chunk. Larger
    ///     values reduce overhead but increase latency before the first estimate.
    ///   - minimumDuration: Files shorter than half this value are looped in-memory
    ///     to provide enough material for detection. Pass `nil` to disable looping.
    ///   - matchesRequired: Number of consistent periodic estimates needed
    ///     to stop early. Pass `nil` to process the entire file.
    ///   - tolerance: BPM tolerance for consensus matching. When greater than zero,
    ///     two estimates within this range are considered equivalent.
    ///   - options: Detection algorithm options (quality, BPM range, etc.).
    ///   - eventHandler: Optional callback for progress and completion events.
    /// - Throws: If the audio file cannot be opened.
    public init(
        url: URL,
        bufferDuration: TimeInterval = 1,
        minimumDuration: TimeInterval? = 15,
        matchesRequired: Int? = nil,
        tolerance: Double = 0,
        options: BpmDetection.Options = .init(quality: .balanced),
        eventHandler: URLProgressEventHandler? = nil
    ) throws {
        let audioFile = try AVAudioFile(forReading: url)

        self.init(
            audioFile: audioFile,
            bufferDuration: bufferDuration,
            minimumDuration: minimumDuration,
            matchesRequired: matchesRequired,
            tolerance: tolerance,
            options: options,
            eventHandler: eventHandler
        )
    }

    /// Creates a BPM analyzer for an already-opened audio file.
    ///
    /// - Parameters:
    ///   - audioFile: An open `AVAudioFile` to analyze.
    ///   - bufferDuration: Duration in seconds of each analysis chunk.
    ///   - minimumDuration: Files shorter than half this value are looped in-memory.
    ///     Pass `nil` to disable looping.
    ///   - matchesRequired: Number of consistent periodic estimates needed to stop early.
    ///   - tolerance: BPM tolerance for consensus matching.
    ///   - options: Detection algorithm options.
    ///   - eventHandler: Optional callback for progress and completion events.
    public init(
        audioFile: AVAudioFile,
        bufferDuration: TimeInterval = 1,
        minimumDuration: TimeInterval? = 15,
        matchesRequired: Int? = nil,
        tolerance: Double = 0,
        options: BpmDetection.Options = .init(),
        eventHandler: URLProgressEventHandler? = nil
    ) {
        self.bufferDuration = max(0.1, bufferDuration)
        self.minimumDuration = minimumDuration
        self.eventHandler = eventHandler
        self.audioFile = audioFile

        if tolerance > 0 {
            results = CountableResult(matchesRequired: matchesRequired) { a, b in
                a.isMultiple(of: b, tolerance: tolerance)
            }
        } else {
            results = CountableResult(matchesRequired: matchesRequired)
        }

        bpmDetection = BpmDetection(
            sampleRate: audioFile.processingFormat.sampleRate.float,
            options: options
        )
    }

    /// Runs the BPM analysis and returns the detected tempo.
    ///
    /// Streams the audio file through the detection engine, periodically estimating
    /// tempo and collecting results for consensus voting. If `matchesRequired` was set,
    /// processing stops early once enough consistent estimates are collected.
    ///
    /// - Returns: The detected tempo as a ``Bpm`` value.
    /// - Throws: If no tempo could be determined from the audio content.
    public func process() async throws -> Bpm {
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

        _ = await processTask?.result

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

            if let bpm = Bpm(value),
               results.append(bpm)
            { // true and it thinks it has a solid Bpm, so cancel the task
                processTask?.cancel()

                Log.debug("periodicProgress met matches required:", value)
            }

        case .data(format: _, length: let length, samples: let samples):
            bpmDetection.process(samples.pointee, Int(length))

        case .complete:
            // Final estimation with all accumulated data
            let value = bpmDetection.estimateTempo().rounded(.toNearestOrAwayFromZero)
            if let bpm = Bpm(value) {
                _ = results.append(bpm)
            }
        }
    }
}
