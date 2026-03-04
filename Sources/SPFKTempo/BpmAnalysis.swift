// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase

public actor BpmAnalysis: Sendable {
    private let bufferDuration: TimeInterval
    private let eventHandler: URLProgressEventHandler?
    private var bpmDetection: BpmDetection
    private let audioFile: AVAudioFile
    private var results: CountableResult<Bpm>

    var processTask: Task<Void, Error>?

    public init(
        url: URL,
        bufferDuration: TimeInterval = 1,
        matchesRequired: Int? = nil,
        tolerance: Double = 0,
        options: BpmDetection.Options = .init(quality: .balanced),
        eventHandler: URLProgressEventHandler? = nil
    ) throws {
        let audioFile = try AVAudioFile(forReading: url)

        self.init(
            audioFile: audioFile,
            bufferDuration: bufferDuration,
            matchesRequired: matchesRequired,
            tolerance: tolerance,
            options: options,
            eventHandler: eventHandler
        )
    }

    public init(
        audioFile: AVAudioFile,
        bufferDuration: TimeInterval = 1,
        matchesRequired: Int? = nil,
        tolerance: Double = 0,
        options: BpmDetection.Options = .init(),
        eventHandler: URLProgressEventHandler? = nil
    ) {
        self.bufferDuration = max(0.1, bufferDuration)
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

    public func process() async throws -> Bpm {
        processTask = Task<Void, Error> {
            let audioAnalysis = AudioFileScanner(
                bufferDuration: bufferDuration,
                sendPeriodicProgressEvery: 4,
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

            if let bpm = Bpm(value),
               results.append(bpm)
            { // true and it thinks it has a solid Bpm, so cancel the task
                processTask?.cancel()
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
