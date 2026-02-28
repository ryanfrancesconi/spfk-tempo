import Foundation
import Testing

@testable import SPFKTempo

@Suite("BpmDetection Core")
struct BpmDetectionCoreTests {
    @Test("Options defaults are sane")
    func optionsDefaults() {
        let options = BpmDetection.Options()

        #expect(options.bpmRange == 40 ... 300)
        #expect(options.beatsPerBar == 4)
        #expect(options.perceptualWeightingAmount == 0.0)
        #expect(options.templateBlend == 0.35)
    }

    @Test("Batch array and pointer APIs agree")
    func batchArrayAndPointerApisAgree() {
        let sampleRate: Float = 48_000
        let sourceBpm = 120.0
        let samples = Self.makeClickTrack(bpm: sourceBpm, sampleRate: Double(sampleRate), durationSeconds: 30)

        let options = BpmDetection.Options(bpmRange: 40 ... 300)

        let arrayDetector = BpmDetection(sampleRate: sampleRate, options: options)
        let arrayTempo = arrayDetector.estimateTempoOfSamples(samples)

        let pointerTempo = samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                Issue.record("Missing sample buffer baseAddress")
                return 0.0
            }
            let pointerDetector = BpmDetection(sampleRate: sampleRate, options: options)
            return pointerDetector.estimateTempoOfSamples(baseAddress, buffer.count)
        }

        #expect(abs(arrayTempo - pointerTempo) < 0.25)
    }

    @Test("Streaming process and batch process are consistent")
    func streamingAndBatchProcessAreConsistent() {
        let sampleRate: Float = 48_000
        let sourceBpm = 96.0
        let samples = Self.makeClickTrack(bpm: sourceBpm, sampleRate: Double(sampleRate), durationSeconds: 35)

        let options = BpmDetection.Options(bpmRange: 40 ... 300)

        let batchDetector = BpmDetection(sampleRate: sampleRate, options: options)
        let batchTempo = batchDetector.estimateTempoOfSamples(samples)

        let streamDetector = BpmDetection(sampleRate: sampleRate, options: options)
        var index = 0
        let chunkSize = 4096
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            streamDetector.process(Array(samples[index ..< end]))
            index = end
        }
        let streamTempo = streamDetector.estimateTempo()

        #expect(abs(batchTempo - streamTempo) < 0.75)
    }

    @Test("Detected tempo is near expected family for click tracks")
    func detectedTempoNearExpectedFamily() {
        let sampleRate: Float = 48_000
        let options = BpmDetection.Options(bpmRange: 40 ... 300)
        let sourceBpms: [Double] = [60, 90, 140]

        for sourceBpm in sourceBpms {
            let samples = Self.makeClickTrack(bpm: sourceBpm, sampleRate: Double(sampleRate), durationSeconds: 40)
            let detector = BpmDetection(sampleRate: sampleRate, options: options)
            let detectedTempo = detector.estimateTempoOfSamples(samples)

            let error = Self.bestFamilyError(observedBpm: detectedTempo, sourceBpm: sourceBpm)
            #expect(error <= 1.5, "Expected family error <= 1.5 for \(sourceBpm), got \(detectedTempo)")
        }
    }

    @Test("BPM range constrains output")
    func bpmRangeConstrainsOutput() {
        let sampleRate: Float = 48_000
        let sourceBpm = 60.0
        let options = BpmDetection.Options(bpmRange: 80 ... 100)
        let samples = Self.makeClickTrack(bpm: sourceBpm, sampleRate: Double(sampleRate), durationSeconds: 30)

        let detector = BpmDetection(sampleRate: sampleRate, options: options)
        let detectedTempo = detector.estimateTempoOfSamples(samples)

        #expect(detectedTempo == 0.0 || options.bpmRange.contains(Float(detectedTempo)))
    }

    @Test("reset clears tempo candidates")
    func resetClearsTempoCandidates() {
        let sampleRate: Float = 48_000
        let sourceBpm = 120.0
        let samples = Self.makeClickTrack(bpm: sourceBpm, sampleRate: Double(sampleRate), durationSeconds: 25)

        let detector = BpmDetection(sampleRate: sampleRate)
        detector.process(samples)
        _ = detector.estimateTempo()

        #expect(!detector.getTempoCandidates().isEmpty)

        detector.reset()
        #expect(detector.getTempoCandidates().isEmpty)
    }

    private static func makeClickTrack(
        bpm: Double,
        sampleRate: Double,
        durationSeconds: Double
    ) -> [Float] {
        let sampleCount = Int(sampleRate * durationSeconds)
        let beatInterval = max(1, Int((60.0 / bpm) * sampleRate))
        let clickLength = max(1, Int(sampleRate * 0.015))

        var samples = Array(repeating: Float(0), count: sampleCount)
        var beatIndex = 0
        var sampleIndex = 0

        while sampleIndex < sampleCount {
            let accent: Float = (beatIndex % 4 == 0) ? 1.0 : 0.75
            for clickOffset in 0 ..< clickLength {
                let idx = sampleIndex + clickOffset
                if idx >= sampleCount { break }
                let env = exp(-Double(clickOffset) / (sampleRate * 0.003))
                samples[idx] += Float(env) * accent
            }
            beatIndex += 1
            sampleIndex += beatInterval
        }

        return samples
    }

    private static func bestFamilyError(observedBpm: Double, sourceBpm: Double) -> Double {
        let family = [sourceBpm / 2.0, sourceBpm, sourceBpm * 2.0]
        return family.map { abs(observedBpm - $0) }.min() ?? .infinity
    }
}
