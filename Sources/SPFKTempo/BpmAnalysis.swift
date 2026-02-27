// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
@preconcurrency import SPFKTempoC

public actor BpmAnalysis: Sendable {
    private let bufferDuration: TimeInterval
    private let eventHandler: URLProgressEventHandler?
    private let matchesRequired: Int?
    private let bpmDetect: DetectTempo
    private let audioFile: AVAudioFile
    private let results: BpmResults

    public init(
        url: URL,
        bufferDuration: TimeInterval = 0.2,
        matchesRequired: Int? = nil,
        eventHandler: URLProgressEventHandler? = nil
    ) throws {
        let audioFile = try AVAudioFile(forReading: url)

        self.init(
            audioFile: audioFile,
            bufferDuration: bufferDuration,
            matchesRequired: matchesRequired,
            eventHandler: eventHandler
        )
    }

    public init(
        audioFile: AVAudioFile,
        bufferDuration: TimeInterval = 0.2,
        matchesRequired: Int? = nil,
        eventHandler: URLProgressEventHandler? = nil
    ) {
        self.bufferDuration = max(0.1, bufferDuration)
        self.matchesRequired = matchesRequired
        self.eventHandler = eventHandler
        self.audioFile = audioFile

        results = BpmResults(matchesRequired: matchesRequired)
        bpmDetect = DetectTempo(format: audioFile.processingFormat)
    }

    var processTask: Task<Void, Error>?

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

        guard let bpm = await results.mostLikelyBpm() else {
            throw NSError(description: "Failed to detect bpm")
        }

        return bpm
    }

    private func analyze(_ event: AudioFileScannerEvent) async {
        switch event {
        case .progress(url: let url, value: let value):
            await eventHandler?(.progress(url: url, value: value))

        case .periodicProgress:
            let value = Double(bpmDetect.getBpm()).rounded(.toNearestOrAwayFromZero)

            if let bpm = Bpm(value),
                await results.append(bpm)
            { // true and it thinks it has a solid Bpm, so cancel the task
                processTask?.cancel()
            }

        case .data(format: _, length: let length, samples: let samples):
            bpmDetect.process(
                samples.pointee,
                numberOfSamples: Int32(length)
            )

        case .complete:
            break
        }
    }
}

actor BpmResults {
    private var results: [Bpm] = []
    private var suggestedValue: Bpm?
    private let matchesRequired: Int?

    init(matchesRequired: Int?) {
        self.matchesRequired = matchesRequired
    }

    /// Append a `Bpm` value
    /// - Parameter value: The `Bpm` to add to the results
    /// - Returns: `true` if enough values are present to suggest a confident value, `false` otherwise
    func append(_ value: Bpm) -> Bool {
        results.append(value)

        let count = results.count(of: value)

        Log.debug("\(value) \(count)/\(matchesRequired?.string ?? "nil")")

        if let matchesRequired, count >= matchesRequired {
            Log.debug("Returning early found \(count) duplicates of", value)
            suggestedValue = value
            return true
        }

        return false
    }

    func mostLikelyBpm() -> Bpm? {
        if let suggestedValue { return suggestedValue }

        guard results.isNotEmpty else {
            return nil
        }

        return Self.mostLikelyBpm(from: results)
    }

    /// Given a list of Bpm values, which value occurs the most in the array
    /// - Parameter results: list of Bpms to check
    /// - Returns: A suggested single value
    static func mostLikelyBpm(from results: [Bpm]) -> Bpm? {
        // order bpms by how many repeat values there are
        let frequencyMap: [(key: Bpm, value: Int)] = results.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }.sorted { lhs, rhs in
            lhs.value > rhs.value
        }

        guard let value = frequencyMap.first else {
            Log.error("failed to detect bpm")
            return nil
        }

        Log.debug("sorted results:", frequencyMap)

        return value.key
    }
}
