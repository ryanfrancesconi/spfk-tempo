// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

public final class BpmDetection {
    /// Controls the tradeoff between detection speed and accuracy.
    /// Higher quality uses more overlapping analysis windows for finer onset resolution.
    public enum AnalysisQuality: Int, Sendable {
        /// No overlap. ~4x faster than `.accurate`, suitable for strong rhythmic material.
        case fast = 1
        /// 50% overlap. ~2x faster than `.accurate`, good general-purpose default.
        case balanced = 2
        /// 75% overlap. Most accurate onset detection, highest CPU cost.
        case accurate = 4
    }

    public struct Options {
        public var quality: AnalysisQuality
        public var bpmRange: ClosedRange<Float>
        public var beatsPerBar: Int
        /// 0.0 = no perceptual tempo bias (most neutral/accurate),
        /// 1.0 = full legacy weighting toward mid-tempo.
        public var perceptualWeightingAmount: Float

        public init(
            quality: AnalysisQuality = .balanced,
            bpmRange: ClosedRange<Float> = 40 ... 300,
            beatsPerBar: Int = 4,
            perceptualWeightingAmount: Float = 0.0
        ) {
            self.quality = quality
            self.bpmRange = bpmRange
            self.beatsPerBar = beatsPerBar
            self.perceptualWeightingAmount = perceptualWeightingAmount
        }
    }

    // MARK: - Internal DSP tuning constants

    /// Log-compression factor applied to spectral magnitudes before computing onset flux.
    /// Higher values emphasize quieter onsets; lower values favor loud transients.
    private let fluxCompression: Float = 2.0

    /// Weight for the fundamental lag in the harmonic template scorer.
    private let harmonicWeight1: Float = 1.0
    /// Weight for the 2x lag (half-tempo harmonic) in the template scorer.
    private let harmonicWeight2: Float = 0.25
    /// Weight for the 3x lag (third-tempo harmonic) in the template scorer.
    private let harmonicWeight3: Float = 0.10
    /// Weight for the 4x lag (quarter-tempo harmonic) in the template scorer.
    private let harmonicWeight4: Float = 0.05

    /// Penalty applied when the half-lag (double-tempo) shows a strong peak,
    /// reducing octave-error false positives (e.g. picking 240 instead of 120).
    private let harmonicPenalty2: Float = 0.10
    /// Penalty applied when the third-lag (triple-tempo) shows a strong peak.
    private let harmonicPenalty3: Float = 0.03

    /// Blend between comb-filter score (0.0) and harmonic template score (1.0)
    /// for the final candidate ranking.
    private let templateBlend: Float = 0.35

    /// Autocorrelation weight for the low-frequency band (0–550 Hz).
    /// Kick drums and bass onsets dominate here.
    private let lowFrequencyWeight: Float = 1.0
    /// Autocorrelation weight for the mid-frequency band (550–4000 Hz).
    /// Snare, vocals, and harmonic content.
    private let midFrequencyWeight: Float = 0.8
    /// Autocorrelation weight for the high-frequency band (4000–16000 Hz).
    /// Hi-hats and cymbal transients.
    private let highFrequencyWeight: Float = 0.5
    /// Autocorrelation weight for the broadband RMS energy envelope.
    /// Provides a coarse overall loudness signal.
    private let rmsWeight: Float = 0.1

    public var options: Options

    /// The sample rate of the input audio signal in Hz.
    private let inputSampleRate: Float

    /// FFT analysis frame size in samples. Fixed at 2048 for frequency resolution.
    private let blockSize: Int

    /// Hop size between successive analysis frames, derived from blockSize / quality.
    /// Smaller values increase overlap and accuracy at the cost of speed.
    private let stepSize: Int

    /// Filterbank extracting spectral energy in the low frequency band (0–550 Hz).
    /// Captures kick drum and bass content.
    private let lowFrequencyFilterbank: FourierFilterbank

    /// Filterbank extracting spectral energy in the mid frequency band (550–4000 Hz).
    /// Captures snare, vocals, and harmonic content.
    private let midFrequencyFilterbank: FourierFilterbank

    /// Filterbank extracting spectral energy in the high frequency band (4–16 kHz).
    /// Captures hi-hats, cymbals, and transient content.
    private let highFrequencyFilterbank: FourierFilterbank

    /// FFT-based autocorrelation engine used to find periodic peaks in onset signals.
    private let autocorrelation = AutocorrelationFFT()

    /// Accumulated spectral flux values for the low frequency band across all analyzed frames.
    private var lowFrequencyFlux: [Float] = []

    /// Accumulated spectral flux values for the mid frequency band across all analyzed frames.
    private var midFrequencyFlux: [Float] = []

    /// Accumulated spectral flux values for the high frequency band across all analyzed frames.
    private var highFrequencyFlux: [Float] = []

    /// RMS energy envelope computed per analysis block, used as a broadband onset signal.
    private var blockRmsEnvelope: [Float] = []

    /// BPM candidates collected from each `estimateTempo()` call for final consensus.
    private var tempoCandidates: [Double] = []

    /// Scratch buffer for accumulating incoming audio samples into full analysis blocks.
    private var inputBlock: [Float]

    /// Buffer holding leftover samples that didn't fill a complete step in the previous call.
    private var pendingStepSamples: [Float]

    /// Number of valid samples currently stored in `pendingStepSamples`.
    private var pendingStepFillCount = 0

    /// Previous frame's magnitude spectrum for the low frequency band (used to compute flux).
    private var lowFrequencyPreviousSpectrum: [Float]

    /// Previous frame's magnitude spectrum for the mid frequency band (used to compute flux).
    private var midFrequencyPreviousSpectrum: [Float]

    /// Previous frame's magnitude spectrum for the high frequency band (used to compute flux).
    private var highFrequencyPreviousSpectrum: [Float]

    /// Current frame's magnitude spectrum for the low frequency band.
    private var lowFrequencySpectrum: [Float]

    /// Current frame's magnitude spectrum for the mid frequency band.
    private var midFrequencySpectrum: [Float]

    /// Current frame's magnitude spectrum for the high frequency band.
    private var highFrequencySpectrum: [Float]

    /// Scratch buffer for the weighted sum of per-band autocorrelation results.
    private var autocorrelationBuffer: [Float] = []

    /// Temporary buffer used internally by the autocorrelation engine.
    private var autocorrelationScratch: [Float] = []

    /// Scratch buffer for comb filter scoring of tempo candidates.
    private var combFilterBuffer: [Float] = []

    /// Scratch buffer for harmonic template matching scores at each candidate lag.
    private var templateScores: [Float] = []

    public init(sampleRate: Float, options: Options = Options()) {
        self.options = options
        inputSampleRate = sampleRate

        let lfMin: Float = 0
        let lfMax: Float = 550
        let mfMin: Float = 550
        let mfMax: Float = 4000
        let hfMin: Float = 4000
        let hfMax: Float = 16000
        let lfBinMax = 6

        blockSize = Int((inputSampleRate * Float(lfBinMax)) / lfMax)
        stepSize = max(1, blockSize / options.quality.rawValue)

        lowFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: lfMin, maxFreq: lfMax, windowed: true
        )
        midFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: mfMin, maxFreq: mfMax, windowed: true
        )
        highFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: hfMin, maxFreq: hfMax, windowed: true
        )

        inputBlock = Array(repeating: 0, count: blockSize)
        pendingStepSamples = Array(repeating: 0, count: stepSize)

        lowFrequencyPreviousSpectrum = Array(repeating: 0, count: lowFrequencyFilterbank.outputBinCount)
        midFrequencyPreviousSpectrum = Array(repeating: 0, count: midFrequencyFilterbank.outputBinCount)
        highFrequencyPreviousSpectrum = Array(repeating: 0, count: highFrequencyFilterbank.outputBinCount)
        lowFrequencySpectrum = Array(repeating: 0, count: lowFrequencyFilterbank.outputBinCount)
        midFrequencySpectrum = Array(repeating: 0, count: midFrequencyFilterbank.outputBinCount)
        highFrequencySpectrum = Array(repeating: 0, count: highFrequencyFilterbank.outputBinCount)
    }

    @inline(__always)
    private func reserveForIncomingSamples(_ nsamples: Int) {
        let estimatedFrames = max(0, nsamples / max(stepSize, 1))
        if estimatedFrames > 0 {
            lowFrequencyFlux.reserveCapacity(lowFrequencyFlux.count + estimatedFrames)
            midFrequencyFlux.reserveCapacity(midFrequencyFlux.count + estimatedFrames)
            highFrequencyFlux.reserveCapacity(highFrequencyFlux.count + estimatedFrames)
            blockRmsEnvelope.reserveCapacity(blockRmsEnvelope.count + estimatedFrames)
        }
    }

    @inline(__always)
    private func positiveSpectralFlux(_ current: [Float], _ previous: [Float]) -> Float {
        // Compressed positive flux is more onset-focused and less noisy than raw power diff.
        let compression = max(0.0001, fluxCompression)
        var total: Float = 0
        for i in 0 ..< current.count {
            let c = log1p(current[i] * compression)
            let p = log1p(previous[i] * compression)
            let d = c - p
            if d > 0 { total += d }
        }
        return total
    }

    private func processInputBlock() {
        var blockEnergy: Float = 0
        for sample in inputBlock {
            blockEnergy += sample * sample
        }
        blockRmsEnvelope.append(sqrt(blockEnergy / Float(blockSize)))

        inputBlock.withUnsafeBufferPointer { inBuf in
            lowFrequencySpectrum.withUnsafeMutableBufferPointer { outBuf in
                lowFrequencyFilterbank.forwardMagnitude(input: inBuf, output: outBuf)
            }
        }
        lowFrequencyFlux.append(positiveSpectralFlux(lowFrequencySpectrum, lowFrequencyPreviousSpectrum))
        lowFrequencyPreviousSpectrum = lowFrequencySpectrum

        inputBlock.withUnsafeBufferPointer { inBuf in
            midFrequencySpectrum.withUnsafeMutableBufferPointer { outBuf in
                midFrequencyFilterbank.forwardMagnitude(input: inBuf, output: outBuf)
            }
        }
        midFrequencyFlux.append(positiveSpectralFlux(midFrequencySpectrum, midFrequencyPreviousSpectrum))
        midFrequencyPreviousSpectrum = midFrequencySpectrum

        inputBlock.withUnsafeBufferPointer { inBuf in
            highFrequencySpectrum.withUnsafeMutableBufferPointer { outBuf in
                highFrequencyFilterbank.forwardMagnitude(input: inBuf, output: outBuf)
            }
        }
        highFrequencyFlux.append(positiveSpectralFlux(highFrequencySpectrum, highFrequencyPreviousSpectrum))
        highFrequencyPreviousSpectrum = highFrequencySpectrum
    }

    public func estimateTempoOfSamples(_ samples: UnsafePointer<Float>, _ nsamples: Int) -> Double {
        let buf = UnsafeBufferPointer(start: samples, count: nsamples)
        return estimateTempoOfSamples(buf)
    }

    public func process(_ samples: UnsafePointer<Float>, _ nsamples: Int) {
        let buf = UnsafeBufferPointer(start: samples, count: nsamples)
        process(buf)
    }

    public func estimateTempoOfSamples(_ samples: [Float]) -> Double {
        samples.withUnsafeBufferPointer { estimateTempoOfSamples($0) }
    }

    public func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    public func estimateTempo() -> Double {
        if pendingStepFillCount > 0 {
            let hole = blockSize - stepSize
            for i in 0 ..< pendingStepFillCount {
                inputBlock[hole + i] = pendingStepSamples[i]
            }
            for i in pendingStepFillCount ..< stepSize {
                inputBlock[hole + i] = 0
            }
            pendingStepFillCount = 0
            processInputBlock()
        }
        return finish()
    }

    public func getTempoCandidates() -> [Double] {
        tempoCandidates
    }

    public func reset() {
        lowFrequencyFlux.removeAll(keepingCapacity: true)
        midFrequencyFlux.removeAll(keepingCapacity: true)
        highFrequencyFlux.removeAll(keepingCapacity: true)
        blockRmsEnvelope.removeAll(keepingCapacity: true)
        tempoCandidates.removeAll(keepingCapacity: true)
        pendingStepFillCount = 0

        lowFrequencyPreviousSpectrum.withUnsafeMutableBufferPointer { spectrumBuffer in
            guard let base = spectrumBuffer.baseAddress else { return }
            base.update(repeating: 0, count: spectrumBuffer.count)
        }
        midFrequencyPreviousSpectrum.withUnsafeMutableBufferPointer { spectrumBuffer in
            guard let base = spectrumBuffer.baseAddress else { return }
            base.update(repeating: 0, count: spectrumBuffer.count)
        }
        highFrequencyPreviousSpectrum.withUnsafeMutableBufferPointer { spectrumBuffer in
            guard let base = spectrumBuffer.baseAddress else { return }
            base.update(repeating: 0, count: spectrumBuffer.count)
        }
    }

    private func estimateTempoOfSamples(_ samples: UnsafeBufferPointer<Float>) -> Double {
        reserveForIncomingSamples(samples.count)

        var i = 0
        while i + blockSize <= samples.count {
            for j in 0 ..< blockSize {
                inputBlock[j] = samples[i + j]
            }
            processInputBlock()
            i += stepSize
        }

        return finish()
    }

    private func process(_ samples: UnsafeBufferPointer<Float>) {
        reserveForIncomingSamples(samples.count)

        var consumedSampleCount = 0
        while consumedSampleCount < samples.count {
            let hole = blockSize - stepSize
            let remaining = samples.count - consumedSampleCount

            if pendingStepFillCount + remaining < stepSize {
                for i in 0 ..< remaining {
                    pendingStepSamples[pendingStepFillCount + i] = samples[consumedSampleCount + i]
                }
                pendingStepFillCount += remaining
                break
            }

            for i in 0 ..< pendingStepFillCount {
                inputBlock[hole + i] = pendingStepSamples[i]
            }

            let toConsume = stepSize - pendingStepFillCount
            for i in 0 ..< toConsume {
                inputBlock[hole + pendingStepFillCount + i] = samples[consumedSampleCount + i]
            }

            consumedSampleCount += toConsume
            pendingStepFillCount = 0

            processInputBlock()

            for i in 0 ..< hole {
                inputBlock[i] = inputBlock[i + stepSize]
            }
        }
    }

    /// Subtract a local moving average from the flux signal and half-wave rectify,
    /// producing a normalised onset function that is less sensitive to overall loudness.
    /// The window spans approximately 3 seconds of analysis frames.
    private func normaliseFlux(_ flux: [Float]) -> [Float] {
        let count = flux.count
        guard count > 0 else { return flux }
        let hopsPerSec = inputSampleRate / Float(stepSize)
        let halfWindow = max(4, Int(hopsPerSec * 1.5))
        var normalised = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let windowStart = max(0, i - halfWindow)
            let windowEnd = min(count, i + halfWindow + 1)
            var sum: Float = 0
            for j in windowStart ..< windowEnd {
                sum += flux[j]
            }
            let localMean = sum / Float(windowEnd - windowStart)
            let diff = flux[i] - localMean
            normalised[i] = diff > 0 ? diff : 0
        }
        return normalised
    }

    private func finish() -> Double {
        tempoCandidates.removeAll(keepingCapacity: true)

        let onsetFrameCount = lowFrequencyFlux.count
        if onsetFrameCount == 0 { return 0 }

        // Normalise onset flux signals to reduce loudness bias.
        let normalisedLowFlux = normaliseFlux(lowFrequencyFlux)
        let normalisedMidFlux = normaliseFlux(midFrequencyFlux)
        let normalisedHighFlux = normaliseFlux(highFrequencyFlux)

        let hopsPerSec = inputSampleRate / Float(stepSize)

        let minBPM = options.bpmRange.lowerBound
        let maxBPM = options.bpmRange.upperBound
        let barPM = minBPM / Float(4 * options.beatsPerBar)
        var acfLength = AutocorrelationFFT.bpmToLag(barPM, hopsPerSec: hopsPerSec)
        while acfLength > onsetFrameCount {
            acfLength /= 2
        }
        if acfLength <= 0 { return 0 }

        if autocorrelationBuffer.count < acfLength { autocorrelationBuffer = Array(repeating: 0, count: acfLength) }
        if autocorrelationScratch.count < acfLength { autocorrelationScratch = Array(repeating: 0, count: acfLength) }
        autocorrelationBuffer.withUnsafeMutableBufferPointer { autocorrelationPointer in
            guard let base = autocorrelationPointer.baseAddress else { return }
            base.update(repeating: 0, count: acfLength)
        }

        autocorrelation.acfUnityNormalised(
            input: normalisedLowFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * lowFrequencyWeight
        }

        autocorrelation.acfUnityNormalised(
            input: normalisedMidFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * midFrequencyWeight
        }

        autocorrelation.acfUnityNormalised(
            input: normalisedHighFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * highFrequencyWeight
        }

        autocorrelation.acfUnityNormalised(
            input: blockRmsEnvelope, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * rmsWeight
        }

        let minLag = AutocorrelationFFT.bpmToLag(maxBPM, hopsPerSec: hopsPerSec)
        let maxLag = AutocorrelationFFT.bpmToLag(minBPM, hopsPerSec: hopsPerSec)
        if acfLength < maxLag { return 0 }

        let comb = ACFCombFilter(
            beatsPerBar: options.beatsPerBar, minLag: minLag, maxLag: maxLag, hopsPerSec: hopsPerSec
        )
        let combFilterLength = comb.filteredLength()
        if combFilterBuffer.count < combFilterLength { combFilterBuffer = Array(repeating: 0, count: combFilterLength) }
        if templateScores.count < combFilterLength { templateScores = Array(repeating: 0, count: combFilterLength) }

        comb.filter(
            autocorrelation: autocorrelationBuffer, autocorrelationLength: acfLength, filtered: &combFilterBuffer
        )
        unityNormalise(&combFilterBuffer, count: combFilterLength)

        let blend = max(0.0, min(1.0, options.perceptualWeightingAmount))
        if blend > 0 {
            let center: Float = 130
            for i in 0 ..< combFilterLength {
                let bpm = AutocorrelationFFT.lagToBpm(Float(minLag + i), hopsPerSec: hopsPerSec)
                let dev = abs(center - bpm)
                let width: Float = bpm < center ? 100 : 80
                var legacyWeight = 1.0 - pow(dev / width, 2.4)
                if legacyWeight < 0 { legacyWeight = 0 }

                // Blend legacy weighting with neutral weighting (1.0).
                let weight = 1.0 + (legacyWeight - 1.0) * blend
                combFilterBuffer[i] *= weight
            }
        }

        let templateMix = max(0.0, min(1.0, templateBlend))
        for i in 0 ..< combFilterLength {
            let templateScore = harmonicTemplateScore(
                index: i,
                minLag: minLag,
                maxLag: maxLag,
                combResponse: combFilterBuffer,
                combResponseLength: combFilterLength
            )
            templateScores[i] = combFilterBuffer[i] * (1.0 - templateMix) + templateScore * templateMix
        }
        unityNormalise(&templateScores, count: combFilterLength)

        var peaks: [(score: Float, idx: Int)] = []
        peaks.reserveCapacity(max(8, combFilterLength / 8))

        if combFilterLength >= 3 {
            for i in 1 ..< (combFilterLength - 1) {
                if templateScores[i] > templateScores[i - 1], templateScores[i] > templateScores[i + 1] {
                    peaks.append((templateScores[i], i))
                }
            }
        }

        if peaks.isEmpty { return 0 }
        peaks.sort { $0.score > $1.score }

        var seen = Set<Int>()
        seen.reserveCapacity(peaks.count)

        for peak in peaks {
            let lag = peak.idx + minLag
            let coarseBPM = comb.refine(
                lag: lag, autocorrelation: autocorrelationBuffer, autocorrelationLength: acfLength
            )
            let lagGuess = (60.0 * hopsPerSec) / coarseBPM
            let refinedLag = refineFundamentalLag(
                guessLag: lagGuess,
                autocorrelationSequence: autocorrelationBuffer,
                acfLength: acfLength,
                minLag: minLag,
                maxLag: maxLag
            )
            let bpm = AutocorrelationFFT.lagToBpm(refinedLag, hopsPerSec: hopsPerSec)
            // Scale dedup quantization relative to BPM: ~1 BPM resolution at all tempos.
            let quantised = Int(Double(bpm).rounded())
            if seen.insert(quantised).inserted {
                tempoCandidates.append(Double(bpm))
            }
        }

        return tempoCandidates.first ?? 0
    }

    @inline(__always)
    private func harmonicTemplateScore(
        index: Int,
        minLag: Int,
        maxLag: Int,
        combResponse: [Float],
        combResponseLength: Int
    ) -> Float {
        let lag = minLag + index
        let maxAllowedLag = minLag + combResponseLength - 1
        if lag < minLag || lag > maxAllowedLag || lag > maxLag { return 0 }

        @inline(__always)
        func atLag(_ l: Int) -> Float {
            if l < minLag || l > maxAllowedLag { return 0 }
            return combResponse[l - minLag]
        }

        // Reward consistency at integer multiples of the same period (slower tempos / longer lags).
        var score = atLag(lag) * harmonicWeight1
        score += atLag(lag * 2) * harmonicWeight2
        score += atLag(lag * 3) * harmonicWeight3
        score += atLag(lag * 4) * harmonicWeight4

        // Penalize candidates whose faster harmonics (shorter lags) are strong,
        // reducing over-fast octave errors (e.g. picking 120 instead of 60).
        score -= atLag(max(1, lag / 2)) * harmonicPenalty2
        score -= atLag(max(1, lag / 3)) * harmonicPenalty3

        return max(0, score)
    }

    @inline(__always)
    private func unityNormalise(_ values: inout [Float], count: Int) {
        guard count > 0 else { return }

        var maxValue = values[0]
        var minValue = values[0]

        for i in 1 ..< count {
            let value = values[i]
            if value > maxValue { maxValue = value }
            if value < minValue { minValue = value }
        }

        if maxValue > minValue {
            let scale = 1.0 / (maxValue - minValue)
            for i in 0 ..< count {
                values[i] = (values[i] - minValue) * scale
            }
        }
    }

    @inline(__always)
    private func refineFundamentalLag(
        guessLag: Float,
        autocorrelationSequence: [Float],
        acfLength: Int,
        minLag: Int,
        maxLag: Int
    ) -> Float {
        let center = Int(guessLag.rounded())
        let searchRadius = 5
        let low = max(minLag, max(1, center - searchRadius))
        let high = min(maxLag, min(acfLength - 2, center + searchRadius))
        if low > high { return guessLag }

        var peakIndex = low
        var peak = autocorrelationSequence[low]
        if low < high {
            for i in (low + 1) ... high {
                if autocorrelationSequence[i] > peak {
                    peak = autocorrelationSequence[i]
                    peakIndex = i
                }
            }
        }

        var interpolatedPeakIndex = Float(peakIndex)
        if peakIndex > 0, peakIndex + 1 < acfLength {
            let leftValue = autocorrelationSequence[peakIndex - 1]
            let centerValue = autocorrelationSequence[peakIndex]
            let rightValue = autocorrelationSequence[peakIndex + 1]
            if centerValue > leftValue, centerValue > rightValue {
                let denominator = leftValue - 2 * centerValue + rightValue
                if denominator != 0 {
                    interpolatedPeakIndex += ((leftValue - rightValue) / denominator) / 2
                }
            }
        }
        return interpolatedPeakIndex
    }
}
