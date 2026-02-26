// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTempoC

public struct BpmAnalysis: Sendable {
    private let bufferDuration: TimeInterval
    private let eventHandler: BpmAnalysisEventHandler?
    private let matchesRequired: Int?

    public init(
        bufferDuration: TimeInterval = 0.2,
        matchesRequired: Int? = nil,
        eventHandler: BpmAnalysisEventHandler? = nil
    ) {
        self.bufferDuration = max(0.1, bufferDuration)
        self.matchesRequired = matchesRequired
        self.eventHandler = eventHandler
    }

    public func process(url: URL) async throws -> Bpm {
        try await process(audioFile: AVAudioFile(forReading: url))
    }

    public func process(audioFile: AVAudioFile) async throws -> Bpm {
        Log.debug(audioFile.url.lastPathComponent, audioFile.duration, "seconds")

        // store the current frame before scanning the file
        let currentFrame = audioFile.framePosition

        defer {
            // return the file to frame is was on previously
            audioFile.framePosition = currentFrame
        }

        let results = try await _progress(audioFile: audioFile)

        let bpm = try chooseMostLikelyBpm(from: results)

        await eventHandler?(.complete(url: audioFile.url, value: bpm))

        return bpm
    }

    private func _progress(audioFile: AVAudioFile) async throws -> [Bpm] {
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let totalFramesDouble = Double(totalFrames)
        let pcmFormat: AVAudioFormat = audioFile.processingFormat

        guard totalFrames > 0 else {
            throw NSError(description: "No audio was found in \(audioFile.url.path)")
        }

        func send(progress: UnitInterval) async {
            await eventHandler?(.progress(url: audioFile.url, value: progress))
        }

        // analysis buffer size
        var framesPerBuffer = AVAudioFrameCount(bufferDuration * pcmFormat.sampleRate)

        if framesPerBuffer > totalFrames {
            framesPerBuffer = totalFrames
        }

        Log.debug(pcmFormat)

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: framesPerBuffer
            )
        else {
            throw NSError(description: "Unable to create buffer")
        }

        var currentFrame: AVAudioFramePosition = 0

        // check for rolling bpm every 4 seconds
        let performCheckAt: AVAudioFrameCount = AVAudioFrameCount(pcmFormat.sampleRate) * 4
        var framesSinceLastDetect: AVAudioFrameCount = 0

        var results: [Bpm] = []
        let bpmDetect: DetectTempo = .init(format: pcmFormat)

        while currentFrame < totalFrames {
            try Task.checkCancellation()

            audioFile.framePosition = currentFrame

            let progress: UnitInterval = Double(currentFrame) / totalFramesDouble

            await send(progress: progress)

            try audioFile.read(into: buffer, frameCount: framesPerBuffer)

            if let rawData = buffer.floatChannelData {
                bpmDetect.process(
                    rawData.pointee,
                    numberOfSamples: buffer.frameLength.int32
                )
            }

            currentFrame += AVAudioFramePosition(framesPerBuffer)

            // buffer has reached end of file, trim it
            if currentFrame + AVAudioFramePosition(framesPerBuffer) > totalFrames {
                framesPerBuffer = totalFrames - AVAudioFrameCount(currentFrame)

                guard framesPerBuffer > 0 else { break }
            }

            framesSinceLastDetect += framesPerBuffer

            if framesSinceLastDetect > performCheckAt {
                let value = bpmDetect.getBpm().double.rounded(.toNearestOrAwayFromZero)

                if value > 0, let bpm = Bpm(value) {
                    results.append(bpm)

                    Log.debug(progress, "\(audioFile.url.lastPathComponent) bpm @ \(currentFrame)", bpm)

                    let count = results.count(of: bpm)

                    if let matchesRequired, count >= matchesRequired {
                        Log.debug("Returning early found \(count) duplicates of", bpm)
                        return results
                    }
                }

                framesSinceLastDetect = 0
            }
        }

        return results
    }

    func chooseMostLikelyBpm(from bpms: [Bpm]) throws -> Bpm {
        guard bpms.isNotEmpty else {
            throw NSError(description: "failed to detect bpm")
        }

        // order bpms by how many repeat values there are
        let frequencyMap: [(key: Bpm, value: Int)] = bpms.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }.sorted { lhs, rhs in
            lhs.value > rhs.value
        }

        guard let value = frequencyMap.first else {
            throw NSError(description: "failed to detect bpm")
        }

        Log.debug("sorted results:", frequencyMap)

        return value.key
    }
}
