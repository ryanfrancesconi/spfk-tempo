// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKTesting
import Testing

@testable import SPFKTempo

@Suite("TimePitchRenderer")
struct TimePitchRendererTests {
    private func buffer(channels: Int, frames: Int, sampleRate: Double, fill: (Int, Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for c in 0 ..< channels {
            for i in 0 ..< frames { data[c][i] = fill(c, i) }
        }
        return buffer
    }

    private func noise(channels: Int = 2, frames: Int, sampleRate: Double) throws -> AVAudioPCMBuffer {
        var generator = SystemRandomNumberGenerator()
        return try buffer(channels: channels, frames: frames, sampleRate: sampleRate) { _, _ in
            Float.random(in: -0.5 ... 0.5, using: &generator)
        }
    }

    private func peakIndex(_ buffer: AVAudioPCMBuffer, in range: Range<Int>) throws -> Int {
        let data = try #require(buffer.floatChannelData)
        let range = max(0, range.lowerBound) ..< min(Int(buffer.frameLength), range.upperBound)
        return range.max { abs(data[0][$0]) < abs(data[0][$1]) } ?? range.lowerBound
    }

    // MARK: - Length

    @Test(arguments: [44100.0, 96000.0], [0.5, 0.97, 1.5, 2.0])
    func rendersExactlyRoundFramesOverRate(sampleRate: Double, rate: Double) async throws {
        // Under one block, prime, and longer than a chunk.
        for frames in [1, 509, 48017] {
            let input = try noise(frames: frames, sampleRate: sampleRate)
            let description = TimePitchDescription(rate: rate)
            let output = try await TimePitchRenderer.render(input, description: description, quality: .best)
            #expect(Int(output.frameLength) == description.outputFrameCount(forInput: frames), "\(frames) at \(rate)")
            #expect(output.format == input.format)
        }
    }

    @Test func pitchOnlyKeepsTheLength() async throws {
        let input = try noise(frames: 30000, sampleRate: 48000)
        let output = try await TimePitchRenderer.render(input, description: TimePitchDescription(semitones: 7), quality: .efficient)
        #expect(output.frameLength == input.frameLength)
    }

    @Test func aWrongOutputCountThrows() throws {
        let input = try noise(frames: 4800, sampleRate: 48000)
        let description = TimePitchDescription(rate: 1.5)
        let expected = description.outputFrameCount(forInput: 4800)
        #expect(throws: TimePitchRenderer.RenderError.outputLength(expected: expected, requested: expected - 1)) {
            try TimePitchRenderer.renderSync(
                input, material: 0 ..< 4800, description: description, quality: .best, outputFrames: expected - 1
            )
        }
    }

    // MARK: - Alignment

    @Test(arguments: [0.75, 1.5])
    func clickOnsetsLandAtTheirStretchedTimes(rate: Double) async throws {
        let sampleRate = 48000.0
        let clicks = stride(from: 0.13, to: 3.9, by: 0.25).map { Int(($0 * sampleRate).rounded()) }
        let source = try buffer(channels: 2, frames: Int(4 * sampleRate), sampleRate: sampleRate) { _, i in
            clicks.contains(i) ? 0.9 : 0
        }
        // A trimmed window from 1 s to 3 s, with the rest of the buffer as context.
        let window = Int(sampleRate) ..< Int(3 * sampleRate)
        let output = try await TimePitchRenderer.render(
            source, material: window, description: TimePitchDescription(rate: rate), quality: .best
        )

        let interval = Int(sampleRate * 0.03)
        for click in clicks where window.contains(click) {
            let expected = Int((Double(click - window.lowerBound) / rate).rounded())
            let found = try peakIndex(output, in: expected - 2 * interval ..< expected + 2 * interval + 1)
            #expect(abs(found - expected) <= interval, "click at \(click)")
        }
    }

    // MARK: - Identity and context

    @Test func anEmptyDescriptionReturnsTheMaterialExactly() async throws {
        let file = try AVAudioFile(forReading: TestBundleResources.shared.tabla_wav)
        let source = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let sampleRate = file.processingFormat.sampleRate
        let window = Int(sampleRate) ..< Int(2 * sampleRate)

        let output = try await TimePitchRenderer.render(
            source, material: window, description: TimePitchDescription(formantCorrection: true), quality: .best
        )
        let a = try #require(output.floatChannelData), b = try #require(source.floatChannelData)
        #expect(Int(output.frameLength) == window.count)
        for c in 0 ..< Int(source.format.channelCount) {
            #expect(Array(UnsafeBufferPointer(start: a[c], count: window.count))
                == Array(UnsafeBufferPointer(start: b[c] + window.lowerBound, count: window.count)))
        }
    }

    @Test func contextGrowsWithTheRate() throws {
        let slow = try TimePitchRenderer.contextFrames(for: TimePitchDescription(rate: 0.5), sampleRate: 48000, channelCount: 2, quality: .best)
        let fast = try TimePitchRenderer.contextFrames(for: TimePitchDescription(rate: 2), sampleRate: 48000, channelCount: 2, quality: .best)
        #expect(slow.pre > 0 && slow.post > 0)
        #expect(fast.pre > slow.pre)
        #expect(fast.post > slow.post)
    }

    // MARK: - Refusals

    @Test func refusesMaterialOutsideTheBuffer() async throws {
        let input = try noise(frames: 1000, sampleRate: 48000)
        await #expect(throws: TimePitchRenderer.RenderError.materialOutOfRange) {
            _ = try await TimePitchRenderer.render(input, material: 500 ..< 1500, description: TimePitchDescription(rate: 2), quality: .best)
        }
    }

    @Test func refusesInterleavedInput() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        input.frameLength = 100
        await #expect(throws: TimePitchRenderer.RenderError.unsupportedFormat) {
            _ = try await TimePitchRenderer.render(input, description: TimePitchDescription(rate: 2), quality: .best)
        }
    }

    @Test func silenceOutOfAudioIsAFailure() throws {
        let loud = try noise(channels: 1, frames: 100, sampleRate: 48000)
        let silent = try buffer(channels: 1, frames: 100, sampleRate: 48000) { _, _ in 0 }
        let loudData = try #require(loud.floatChannelData), silentData = try #require(silent.floatChannelData)

        #expect(throws: TimePitchRenderer.RenderError.noFramesCameOut) {
            try TimePitchRenderer.verifyFramesCameOut(input: loudData, range: 0 ..< 100, output: silentData, frames: 100, channelCount: 1)
        }
        // Silence in, silence out is correct.
        try TimePitchRenderer.verifyFramesCameOut(input: silentData, range: 0 ..< 100, output: silentData, frames: 100, channelCount: 1)
        try TimePitchRenderer.verifyFramesCameOut(input: loudData, range: 0 ..< 100, output: loudData, frames: 100, channelCount: 1)
    }
}
