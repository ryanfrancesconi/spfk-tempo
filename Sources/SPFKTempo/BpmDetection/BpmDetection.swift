// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import Foundation

/// Core BPM detection engine using multi-band spectral flux and autocorrelation.
///
/// Decomposes mono audio into three frequency bands (low, mid, high), computes
/// onset strength via positive spectral flux, then runs FFT-based autocorrelation
/// and comb-filter scoring to identify the dominant periodicity. A harmonic
/// template matcher reduces octave errors (e.g. 120 vs 60 BPM).
///
/// Supports both batch and streaming usage:
/// - **Batch**: Call ``estimateTempoOfSamples(_:count:)`` with a complete audio buffer.
/// - **Streaming**: Feed chunks via ``process(_:count:)``, then call ``estimateTempo()``
///   when ready for a result.
///
/// For file-level analysis with consensus voting and early exit, use ``BpmAnalysis`` instead.
public final class BpmDetection {
    // MARK: - Internal DSP tuning constants

    /// Compile-time constants for the detection algorithm. Grouped by function
    /// and declared `static` since they don't vary per instance.
    private enum Tuning {
        /// Log-compression factor applied to spectral magnitudes before computing
        /// onset flux. Higher values emphasize quieter onsets; lower values favor
        /// loud transients.
        static let fluxCompression: Float = 2.0

        /// Blend between comb-filter score (0.0) and harmonic template score (1.0)
        /// for the final candidate ranking.
        static let templateBlend: Float = 0.35

        /// Per-band autocorrelation weights controlling how much each frequency
        /// range contributes to the combined periodicity signal.
        enum BandWeights {
            /// Low band (0–550 Hz): kick drums and bass onsets.
            static let low: Float = 1.0
            /// Mid band (550–4000 Hz): snare, vocals, harmonic content.
            static let mid: Float = 0.8
            /// High band (4–16 kHz): hi-hats and cymbal transients.
            static let high: Float = 0.5
            /// Broadband RMS energy envelope.
            static let rms: Float = 0.1
        }

        /// Weights and penalties for the harmonic template scorer that reduces
        /// octave errors (e.g. picking 120 instead of 60 BPM).
        enum HarmonicTemplate {
            /// Weight for the fundamental lag.
            static let weight1: Float = 1.0
            /// Weight for the 2× lag (half-tempo harmonic).
            static let weight2: Float = 0.25
            /// Weight for the 3× lag (third-tempo harmonic).
            static let weight3: Float = 0.10
            /// Weight for the 4× lag (quarter-tempo harmonic).
            static let weight4: Float = 0.05
            /// Penalty when the half-lag (double-tempo) shows a strong peak.
            static let penalty2: Float = 0.10
            /// Penalty when the third-lag (triple-tempo) shows a strong peak.
            static let penalty3: Float = 0.03
        }

    }

    /// The current detection options. Can be modified between calls.
    public var options: BpmDetectionOptions

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
    private var _tempoCandidates: [Double] = []

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

    /// Creates a BPM detection engine for audio at the given sample rate.
    ///
    /// - Parameters:
    ///   - sampleRate: The sample rate of the input audio in Hz.
    ///   - options: Detection algorithm options.
    public init(sampleRate: Float, options: BpmDetectionOptions = .init()) {
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
        let compression = max(0.0001, Tuning.fluxCompression)
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

    /// Processes a buffer of audio samples and returns the estimated tempo.
    ///
    /// This is a batch convenience method — it processes all samples at once and
    /// returns the result. For streaming usage, call ``process(_:count:)`` followed
    /// by ``estimateTempo()`` separately.
    ///
    /// - Parameters:
    ///   - samples: Pointer to mono Float32 audio samples.
    ///   - count: Number of samples in the buffer.
    /// - Returns: The estimated tempo in BPM, or 0 if detection failed.
    public func estimateTempoOfSamples(_ samples: UnsafePointer<Float>, count: Int) -> Double {
        let buf = UnsafeBufferPointer(start: samples, count: count)
        return estimateTempoOfSamples(buf)
    }

    /// Feeds audio samples into the detection engine for later tempo estimation.
    ///
    /// Call this repeatedly with sequential audio chunks, then call ``estimateTempo()``
    /// to retrieve the result. Handles partial blocks internally.
    ///
    /// - Parameters:
    ///   - samples: Pointer to mono Float32 audio samples.
    ///   - count: Number of samples in the buffer.
    public func process(_ samples: UnsafePointer<Float>, count: Int) {
        let buf = UnsafeBufferPointer(start: samples, count: count)
        process(buf)
    }

    /// Processes a buffer of audio samples and returns the estimated tempo.
    ///
    /// Array convenience overload of ``estimateTempoOfSamples(_:count:)``.
    public func estimateTempoOfSamples(_ samples: [Float]) -> Double {
        samples.withUnsafeBufferPointer { estimateTempoOfSamples($0) }
    }

    /// Feeds audio samples into the detection engine for later tempo estimation.
    ///
    /// Array convenience overload of ``process(_:count:)``.
    public func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    /// Returns the estimated tempo from all audio processed so far.
    ///
    /// Flushes any buffered partial block, then runs the full autocorrelation,
    /// comb-filter, and harmonic-template scoring pipeline. The top candidate
    /// BPM values are available via ``tempoCandidates`` after this call.
    ///
    /// - Returns: The estimated tempo in BPM, or 0 if detection failed.
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

    /// The ranked BPM candidates from the most recent ``estimateTempo()`` call.
    ///
    /// The first element is the top candidate (same value returned by `estimateTempo()`).
    /// Subsequent entries are alternative candidates in descending score order.
    public var tempoCandidates: [Double] { _tempoCandidates }

    /// Clears all accumulated onset data, tempo candidates, and internal buffers.
    ///
    /// Call this to reuse the engine for a different audio signal without
    /// reallocating the DSP resources.
    public func reset() {
        lowFrequencyFlux.removeAll(keepingCapacity: true)
        midFrequencyFlux.removeAll(keepingCapacity: true)
        highFrequencyFlux.removeAll(keepingCapacity: true)
        blockRmsEnvelope.removeAll(keepingCapacity: true)
        _tempoCandidates.removeAll(keepingCapacity: true)
        pendingStepFillCount = 0

        lowFrequencyPreviousSpectrum = Array(repeating: 0, count: lowFrequencyPreviousSpectrum.count)
        midFrequencyPreviousSpectrum = Array(repeating: 0, count: midFrequencyPreviousSpectrum.count)
        highFrequencyPreviousSpectrum = Array(repeating: 0, count: highFrequencyPreviousSpectrum.count)
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
    /// producing a normalized onset function that is less sensitive to overall loudness.
    /// The window spans approximately 3 seconds of analysis frames.
    private func normalizeFlux(_ flux: [Float]) -> [Float] {
        let count = flux.count
        guard count > 0 else { return flux }
        let hopsPerSec = inputSampleRate / Float(stepSize)
        let halfWindow = max(4, Int(hopsPerSec * 1.5))
        var normalized = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let windowStart = max(0, i - halfWindow)
            let windowEnd = min(count, i + halfWindow + 1)
            var sum: Float = 0
            for j in windowStart ..< windowEnd {
                sum += flux[j]
            }
            let localMean = sum / Float(windowEnd - windowStart)
            let diff = flux[i] - localMean
            normalized[i] = diff > 0 ? diff : 0
        }
        return normalized
    }

    /// Runs the full scoring pipeline on accumulated onset data and returns the best BPM.
    ///
    /// Computes weighted multi-band autocorrelation, applies comb-filter and harmonic
    /// template scoring, then picks the strongest peak. A confidence gate rejects
    /// results where the peak doesn't stand out from the background distribution.
    ///
    /// - Returns: The estimated tempo in BPM, or 0 if detection failed or confidence was too low.
    private func finish() -> Double {
        _tempoCandidates.removeAll(keepingCapacity: true)

        let onsetFrameCount = lowFrequencyFlux.count
        if onsetFrameCount == 0 { return 0 }

        // Normalize onset flux signals to reduce loudness bias.
        let normalizedLowFlux = normalizeFlux(lowFrequencyFlux)
        let normalizedMidFlux = normalizeFlux(midFrequencyFlux)
        let normalizedHighFlux = normalizeFlux(highFrequencyFlux)

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

        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] = 0
        }

        autocorrelation.acfUnityNormalized(
            input: normalizedLowFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.low
        }

        autocorrelation.acfUnityNormalized(
            input: normalizedMidFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.mid
        }

        autocorrelation.acfUnityNormalized(
            input: normalizedHighFlux, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.high
        }

        autocorrelation.acfUnityNormalized(
            input: blockRmsEnvelope, lagCount: acfLength, output: &autocorrelationScratch
        )
        for i in 0 ..< acfLength {
            autocorrelationBuffer[i] += autocorrelationScratch[i] * Tuning.BandWeights.rms
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
        unityNormalize(&combFilterBuffer, count: combFilterLength)

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

        let templateMix = max(0.0, min(1.0, Tuning.templateBlend))
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
        unityNormalize(&templateScores, count: combFilterLength)

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

        // Confidence gate: reject results where the best peak doesn't stand out
        // from the background score distribution. For noise-like signals the
        // template scores are nearly uniform, producing a low peak-to-median ratio.
        let confidenceThreshold = options.confidenceLevel.threshold
        if confidenceThreshold > 0 {
            let peakScore = peaks[0].score
            let sortedScores = Array(templateScores[0 ..< combFilterLength]).sorted()
            let medianScore = sortedScores[combFilterLength / 2]
            if medianScore > 0, peakScore / medianScore < confidenceThreshold {
                return 0
            }
        }

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
                _tempoCandidates.append(Double(bpm))
            }
        }

        return _tempoCandidates.first ?? 0
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
        var score = atLag(lag) * Tuning.HarmonicTemplate.weight1
        score += atLag(lag * 2) * Tuning.HarmonicTemplate.weight2
        score += atLag(lag * 3) * Tuning.HarmonicTemplate.weight3
        score += atLag(lag * 4) * Tuning.HarmonicTemplate.weight4

        // Penalize candidates whose faster harmonics (shorter lags) are strong,
        // reducing over-fast octave errors (e.g. picking 120 instead of 60).
        score -= atLag(max(1, lag / 2)) * Tuning.HarmonicTemplate.penalty2
        score -= atLag(max(1, lag / 3)) * Tuning.HarmonicTemplate.penalty3

        return max(0, score)
    }

    @inline(__always)
    private func unityNormalize(_ values: inout [Float], count: Int) {
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
