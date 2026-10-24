// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

@preconcurrency import AVFoundation
import Accelerate
import Foundation
import SPFKAudioBase
import SPFKTimePitchKernel

/// Renders a ``TimePitchDescription`` offline, to exactly `round(frames / rate)` frames.
///
/// It drives the kernel directly rather than through `AVAudioEngine`, so the frame accounting is
/// its own, and it refuses an output that came out silent from an input that was not.
public enum TimePitchRenderer {
    public enum RenderError: Error, Equatable {
        /// The buffer is not deinterleaved 32-bit float.
        case unsupportedFormat
        case materialOutOfRange
        case kernelUnavailable
        /// The kernel refused the output count, which must be `round(material / rate)`.
        case outputLength(expected: Int, requested: Int)
        /// Audio went in and only silence came out.
        case noFramesCameOut
    }

    /// The source frames a render reads beyond each edge of the material. Frames the file does not
    /// have are read as silence. Builds a kernel to ask, so call it once per render, not per buffer.
    public static func contextFrames(
        for description: TimePitchDescription,
        sampleRate: Double,
        channelCount: Int,
        quality: TimePitchQuality
    ) throws -> (pre: Int, post: Int) {
        let kernel = try Kernel(channelCount: channelCount, sampleRate: sampleRate, quality: quality)
        var pre: Int64 = 0, post: Int64 = 0
        TimePitchKernelContextFrames(kernel.ref, description.rate, &pre, &post)
        return (Int(pre), Int(post))
    }

    /// Renders `material`, a frame range of `buffer`; every frame of `buffer` outside it is context.
    ///
    /// An empty description returns a copy of the material.
    @concurrent
    public static func render(
        _ buffer: AVAudioPCMBuffer,
        material: Range<Int>? = nil,
        description: TimePitchDescription,
        quality: TimePitchQuality
    ) async throws -> AVAudioPCMBuffer {
        let material = material ?? 0 ..< Int(buffer.frameLength)
        return try renderSync(
            buffer, material: material, description: description, quality: quality,
            outputFrames: description.outputFrameCount(forInput: material.count)
        )
    }

    static func renderSync(
        _ buffer: AVAudioPCMBuffer,
        material: Range<Int>,
        description: TimePitchDescription,
        quality: TimePitchQuality,
        outputFrames: Int
    ) throws -> AVAudioPCMBuffer {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let input = buffer.floatChannelData else { throw RenderError.unsupportedFormat }
        guard material.lowerBound >= 0, material.upperBound <= Int(buffer.frameLength) else {
            throw RenderError.materialOutOfRange
        }

        let channelCount = Int(format.channelCount)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(outputFrames, 1))),
              let outputData = output.floatChannelData else { throw RenderError.kernelUnavailable }

        if description.isEmpty {
            guard outputFrames == material.count else {
                throw RenderError.outputLength(expected: material.count, requested: outputFrames)
            }
            for c in 0 ..< channelCount {
                outputData[c].update(from: input[c] + material.lowerBound, count: material.count)
            }
            output.frameLength = AVAudioFrameCount(outputFrames)
            return output
        }

        let kernel = try Kernel(channelCount: channelCount, sampleRate: format.sampleRate, quality: quality)
        TimePitchKernelSetTargets(kernel.ref, description.rate, description.transposeFactor)
        TimePitchKernelSetTimbre(
            kernel.ref, description.tonalityLimitHz, description.formantSemitones,
            description.formantCorrection, description.formantBaseHz
        )

        let inputs: [UnsafePointer<Float>?] = (0 ..< channelCount).map { UnsafePointer(input[$0] + material.lowerBound) }
        let outputs: [UnsafeMutablePointer<Float>?] = (0 ..< channelCount).map { outputData[$0] }
        let rendered = TimePitchKernelRenderExact(
            kernel.ref, inputs, Int64(material.count),
            Int64(material.lowerBound), Int64(Int(buffer.frameLength) - material.upperBound),
            outputs, Int64(outputFrames)
        )
        guard rendered else {
            throw RenderError.outputLength(expected: description.outputFrameCount(forInput: material.count), requested: outputFrames)
        }
        output.frameLength = AVAudioFrameCount(outputFrames)

        try verifyFramesCameOut(input: input, range: material, output: outputData, frames: outputFrames, channelCount: channelCount)
        return output
    }

    /// A render path that reports success while emitting silence is the failure nothing else catches.
    static func verifyFramesCameOut(
        input: UnsafePointer<UnsafeMutablePointer<Float>>,
        range: Range<Int>,
        output: UnsafePointer<UnsafeMutablePointer<Float>>,
        frames: Int,
        channelCount: Int
    ) throws {
        func peak(_ samples: UnsafePointer<Float>, _ count: Int) -> Float {
            guard count > 0 else { return 0 }
            var value: Float = 0
            vDSP_maxmgv(samples, 1, &value, vDSP_Length(count))
            return value
        }
        let silence: Float = 1e-6
        let inPeak = (0 ..< channelCount).map { peak(input[$0] + range.lowerBound, range.count) }.max() ?? 0
        guard inPeak > silence else { return }
        let outPeak = (0 ..< channelCount).map { peak(output[$0], frames) }.max() ?? 0
        guard outPeak > silence else { throw RenderError.noFramesCameOut }
    }

    /// Owns one offline kernel.
    private final class Kernel {
        let ref: TimePitchKernelRef

        init(channelCount: Int, sampleRate: Double, quality: TimePitchQuality) throws {
            let kernelQuality: TimePitchKernelQuality = quality == .best ? TimePitchKernelQualityBest : TimePitchKernelQualityEfficient
            guard channelCount > 0,
                  let ref = TimePitchKernelCreate(UInt32(channelCount), sampleRate, 0, kernelQuality, false)
            else { throw RenderError.kernelUnavailable }
            self.ref = ref
        }

        deinit { TimePitchKernelDestroy(ref) }
    }
}
