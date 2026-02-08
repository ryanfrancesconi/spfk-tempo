// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTempoC

public actor BpmAnalysis: Sendable {
    private var task: Task<Bpm, Error>?

    let bufferDuration: TimeInterval

    public var eventHandler: BpmAnalysisEventHandler?
    public func update(eventHandler: BpmAnalysisEventHandler?) {
        self.eventHandler = eventHandler
    }

    public init(bufferDuration: TimeInterval = 0.2) {
        self.bufferDuration = max(0.1, bufferDuration)
    }

    public func process(url: URL) async throws -> Bpm {
        try await process(audioFile: AVAudioFile(forReading: url))
    }

    public func process(audioFile: AVAudioFile) async throws -> Bpm {
        let benchmark = Benchmark(label: "\((#file as NSString).lastPathComponent):\(#function)")
        defer { benchmark.stop() }

        // store the current frame before scanning the file
        let currentFrame = audioFile.framePosition

        defer {
            // return the file to frame is was on previously
            audioFile.framePosition = currentFrame
        }

        let task = Task<Bpm, Error>(priority: .high) {
            try await _process(audioFile: audioFile)
        }

        self.task = task

        let result = await task.result

        guard !task.isCancelled else {
            throw CancellationError()
        }

        switch result {
        case let .success(value):
            return value

        case let .failure(error):
            Log.error("Failed parsing \(audioFile.url)", error)
            throw error
        }
    }

    public func cancel() {
        guard let task else {
            Log.error("task is nil")
            return
        }

        task.cancel()
    }

    private func _process(audioFile: AVAudioFile) async throws -> Bpm {
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let totalFramesDouble = Double(totalFrames)
        let sampleRate = audioFile.fileFormat.sampleRate

        guard totalFrames > 0 else {
            throw NSError(description: "No audio was found in \(audioFile.url.path)")
        }

        func send(progress: UnitInterval) async {
            await eventHandler?(.loading(url: audioFile.url, progress: progress))
        }

        Log.debug(audioFile.url.lastPathComponent, audioFile.duration, "seconds")

        // analysis buffer size
        var framesPerBuffer = AVAudioFrameCount(bufferDuration * sampleRate) // x seconds

        if framesPerBuffer > totalFrames {
            framesPerBuffer = totalFrames
        }

        let pcmFormat: AVAudioFormat = audioFile.processingFormat

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: framesPerBuffer
            )
        else {
            throw NSError(description: "Unable to create buffer")
        }

        var currentFrame: AVAudioFramePosition = 0

        var sinceLastMark: AVAudioFrameCount = 0
        let checkBpmAt: AVAudioFrameCount = AVAudioFrameCount(sampleRate) * 4
        var bpms: [Bpm] = []

        let bpmDetect: BPMDetectC = .init(format: pcmFormat)

        while currentFrame < totalFrames {
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

            sinceLastMark += framesPerBuffer

            if sinceLastMark > checkBpmAt {
                let value = bpmDetect.getBpm().double.rounded(.toNearestOrAwayFromZero)

                if let bpm = try? Bpm(value) {
                    bpms.append(bpm)

                    Log.debug("\(audioFile.url.lastPathComponent) BPM @ \(currentFrame)", bpm)

                    if bpms.count(of: bpm) >= 4 {
                        Log.debug("Returning early found \(bpms) enough multiples of", bpm)
                        return bpm
                    }
                }
                sinceLastMark = 0
            }
        }

        await send(progress: 1)

        return try chooseMostLikelyBpm(from: bpms)
    }

    func chooseMostLikelyBpm(from bpms: [Bpm]) throws -> Bpm {
        guard bpms.isNotEmpty else {
            throw NSError(description: "failed to detect bpm")
        }

        let frequencyMap = bpms.reduce(into: [:]) { counts, value in
            counts[value, default: 0] += 1
        }

        let multiples = frequencyMap.filter { $1 > 1 }.keys

        guard let value = multiples.first else {
            return bpms[0] // unideal, but pick first
        }

        Log.debug("elements which have more than one entry:", multiples, "all:", bpms)

        return value
    }
}
