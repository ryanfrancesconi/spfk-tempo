import Foundation

public final class BpmDetection {
    public struct Options {
        public var bpmRange: ClosedRange<Float>
        public var beatsPerBar: Int
        // 0.0 = no perceptual tempo bias (most neutral/accurate),
        // 1.0 = full legacy weighting toward mid-tempo.
        public var perceptualWeightingAmount: Float
        // Onset feature tuning.
        public var fluxCompression: Float
        // Harmonic template tuning (set all to 0 to fall back to comb-only peak strength).
        public var harmonicWeight1: Float
        public var harmonicWeight2: Float
        public var harmonicWeight3: Float
        public var harmonicWeight4: Float
        public var subharmonicPenalty2: Float
        public var subharmonicPenalty3: Float
        // Blend template score with comb score. 0 = comb only, 1 = template only.
        public var templateBlend: Float

        public init(
            bpmRange: ClosedRange<Float> = 40 ... 300,
            beatsPerBar: Int = 4,
            perceptualWeightingAmount: Float = 0.0,
            fluxCompression: Float = 2.0,
            harmonicWeight1: Float = 1.0,
            harmonicWeight2: Float = 0.25,
            harmonicWeight3: Float = 0.10,
            harmonicWeight4: Float = 0.05,
            subharmonicPenalty2: Float = 0.10,
            subharmonicPenalty3: Float = 0.03,
            templateBlend: Float = 0.35
        ) {
            self.bpmRange = bpmRange
            self.beatsPerBar = beatsPerBar
            self.perceptualWeightingAmount = perceptualWeightingAmount
            self.fluxCompression = fluxCompression
            self.harmonicWeight1 = harmonicWeight1
            self.harmonicWeight2 = harmonicWeight2
            self.harmonicWeight3 = harmonicWeight3
            self.harmonicWeight4 = harmonicWeight4
            self.subharmonicPenalty2 = subharmonicPenalty2
            self.subharmonicPenalty3 = subharmonicPenalty3
            self.templateBlend = templateBlend
        }
    }

    public var options: Options

    private let inputSampleRate: Float
    private let blockSize: Int
    private let stepSize: Int

    private let lowFrequencyFilterbank: FourierFilterbank
    private let highFrequencyFilterbank: FourierFilterbank
    private let autocorrelation = AutocorrelationFFT()

    private var lowFrequencyFlux: [Float] = []
    private var highFrequencyFlux: [Float] = []
    private var blockRmsEnvelope: [Float] = []

    private var tempoCandidates: [Double] = []

    private var inputBlock: [Float]
    private var pendingStepSamples: [Float]
    private var pendingStepFillCount = 0

    private var lowFrequencyPreviousSpectrum: [Float]
    private var highFrequencyPreviousSpectrum: [Float]
    private var lowFrequencySpectrum: [Float]
    private var highFrequencySpectrum: [Float]

    // finish() scratch
    private var autocorrelationBuffer: [Float] = []
    private var autocorrelationScratch: [Float] = []
    private var combFilterBuffer: [Float] = []
    private var templateScores: [Float] = []

    public init(sampleRate: Float, options: Options = Options()) {
        self.options = options
        inputSampleRate = sampleRate

        let lfMin: Float = 0
        let lfMax: Float = 550
        let hfMin: Float = 9000
        let hfMax: Float = 9001
        let lfBinMax = 6

        blockSize = Int((inputSampleRate * Float(lfBinMax)) / lfMax)
        stepSize = max(1, blockSize / 2)

        lowFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: lfMin, maxFreq: lfMax, windowed: true)
        highFrequencyFilterbank = FourierFilterbank(
            n: blockSize, fs: inputSampleRate, minFreq: hfMin, maxFreq: hfMax, windowed: true)

        inputBlock = Array(repeating: 0, count: blockSize)
        pendingStepSamples = Array(repeating: 0, count: stepSize)

        lowFrequencyPreviousSpectrum = Array(repeating: 0, count: lowFrequencyFilterbank.outputBinCount)
        highFrequencyPreviousSpectrum = Array(repeating: 0, count: highFrequencyFilterbank.outputBinCount)
        lowFrequencySpectrum = Array(repeating: 0, count: lowFrequencyFilterbank.outputBinCount)
        highFrequencySpectrum = Array(repeating: 0, count: highFrequencyFilterbank.outputBinCount)
    }

    @inline(__always)
    private func reserveForIncomingSamples(_ nsamples: Int) {
        let estimatedFrames = max(0, nsamples / max(stepSize, 1))
        if estimatedFrames > 0 {
            lowFrequencyFlux.reserveCapacity(lowFrequencyFlux.count + estimatedFrames)
            highFrequencyFlux.reserveCapacity(highFrequencyFlux.count + estimatedFrames)
            blockRmsEnvelope.reserveCapacity(blockRmsEnvelope.count + estimatedFrames)
        }
    }

    @inline(__always)
    private func positiveSpectralFlux(_ current: [Float], _ previous: [Float]) -> Float {
        // Compressed positive flux is more onset-focused and less noisy than raw power diff.
        let compression = max(0.0001, options.fluxCompression)
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
        for sample in inputBlock { blockEnergy += sample * sample }
        blockRmsEnvelope.append(sqrt(blockEnergy / Float(blockSize)))

        inputBlock.withUnsafeBufferPointer { inBuf in
            lowFrequencySpectrum.withUnsafeMutableBufferPointer { outBuf in
                lowFrequencyFilterbank.forwardMagnitude(input: inBuf, output: outBuf)
            }
        }
        lowFrequencyFlux.append(positiveSpectralFlux(lowFrequencySpectrum, lowFrequencyPreviousSpectrum))
        lowFrequencyPreviousSpectrum = lowFrequencySpectrum

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
            for i in 0 ..< pendingStepFillCount { inputBlock[hole + i] = pendingStepSamples[i] }
            for i in pendingStepFillCount ..< stepSize { inputBlock[hole + i] = 0 }
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
        highFrequencyFlux.removeAll(keepingCapacity: true)
        blockRmsEnvelope.removeAll(keepingCapacity: true)
        tempoCandidates.removeAll(keepingCapacity: true)
        pendingStepFillCount = 0

        lowFrequencyPreviousSpectrum.withUnsafeMutableBufferPointer { spectrumBuffer in
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
        while i + blockSize < samples.count {
            for j in 0 ..< blockSize { inputBlock[j] = samples[i + j] }
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

            for i in 0 ..< pendingStepFillCount { inputBlock[hole + i] = pendingStepSamples[i] }

            let toConsume = stepSize - pendingStepFillCount
            for i in 0 ..< toConsume { inputBlock[hole + pendingStepFillCount + i] = samples[consumedSampleCount + i] }

            consumedSampleCount += toConsume
            pendingStepFillCount = 0

            processInputBlock()

            for i in 0 ..< hole { inputBlock[i] = inputBlock[i + stepSize] }
        }
    }

    private func finish() -> Double {
        tempoCandidates.removeAll(keepingCapacity: true)

        let onsetFrameCount = lowFrequencyFlux.count
        if onsetFrameCount == 0 { return 0 }

        let hopsPerSec = inputSampleRate / Float(stepSize)

        let minBPM = options.bpmRange.lowerBound
        let maxBPM = options.bpmRange.upperBound
        let barPM = minBPM / Float(4 * options.beatsPerBar)
        var acfLength = AutocorrelationFFT.bpmToLag(barPM, hopsPerSec: hopsPerSec)
        while acfLength > onsetFrameCount { acfLength /= 2 }
        if acfLength <= 0 { return 0 }

        if autocorrelationBuffer.count < acfLength { autocorrelationBuffer = Array(repeating: 0, count: acfLength) }
        if autocorrelationScratch.count < acfLength { autocorrelationScratch = Array(repeating: 0, count: acfLength) }
        autocorrelationBuffer.withUnsafeMutableBufferPointer { autocorrelationPointer in
            guard let base = autocorrelationPointer.baseAddress else { return }
            base.update(repeating: 0, count: acfLength)
        }

        autocorrelation.acfUnityNormalised(
            input: lowFrequencyFlux, lagCount: acfLength, output: &autocorrelationScratch)
        for i in 0 ..< acfLength { autocorrelationBuffer[i] += autocorrelationScratch[i] }

        autocorrelation.acfUnityNormalised(
            input: highFrequencyFlux, lagCount: acfLength, output: &autocorrelationScratch)
        for i in 0 ..< acfLength { autocorrelationBuffer[i] += autocorrelationScratch[i] * 0.5 }

        autocorrelation.acfUnityNormalised(
            input: blockRmsEnvelope, lagCount: acfLength, output: &autocorrelationScratch)
        for i in 0 ..< acfLength { autocorrelationBuffer[i] += autocorrelationScratch[i] * 0.1 }

        let minLag = AutocorrelationFFT.bpmToLag(maxBPM, hopsPerSec: hopsPerSec)
        let maxLag = AutocorrelationFFT.bpmToLag(minBPM, hopsPerSec: hopsPerSec)
        if acfLength < maxLag { return 0 }

        let comb = ACFCombFilter(
            beatsPerBar: options.beatsPerBar, minLag: minLag, maxLag: maxLag, hopsPerSec: hopsPerSec)
        let combFilterLength = comb.filteredLength()
        if combFilterBuffer.count < combFilterLength { combFilterBuffer = Array(repeating: 0, count: combFilterLength) }
        if templateScores.count < combFilterLength { templateScores = Array(repeating: 0, count: combFilterLength) }

        comb.filter(
            autocorrelation: autocorrelationBuffer, autocorrelationLength: acfLength, filtered: &combFilterBuffer)
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

        let templateMix = max(0.0, min(1.0, options.templateBlend))
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
                if templateScores[i] > templateScores[i - 1] && templateScores[i] > templateScores[i + 1] {
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
                lag: lag, autocorrelation: autocorrelationBuffer, autocorrelationLength: acfLength)
            let lagGuess = (60.0 * hopsPerSec) / coarseBPM
            let refinedLag = refineFundamentalLag(
                guessLag: lagGuess,
                autocorrelationSequence: autocorrelationBuffer,
                acfLength: acfLength,
                minLag: minLag,
                maxLag: maxLag
            )
            let bpm = AutocorrelationFFT.lagToBpm(refinedLag, hopsPerSec: hopsPerSec)
            let gross = Int((Double(bpm) * 2.0).rounded())
            if seen.insert(gross).inserted {
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

        // Reward consistency at integer multiples of the same period.
        var score = atLag(lag) * options.harmonicWeight1
        score += atLag(lag * 2) * options.harmonicWeight2
        score += atLag(lag * 3) * options.harmonicWeight3
        score += atLag(lag * 4) * options.harmonicWeight4

        // Penalize strong subharmonics that often cause over-fast picks.
        score -= atLag(max(1, lag / 2)) * options.subharmonicPenalty2
        score -= atLag(max(1, lag / 3)) * options.subharmonicPenalty3

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
        let low = max(minLag, max(1, center - 2))
        let high = min(maxLag, min(acfLength - 2, center + 2))
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
        let leftValue = autocorrelationSequence[peakIndex - 1]
        let centerValue = autocorrelationSequence[peakIndex]
        let rightValue = autocorrelationSequence[peakIndex + 1]
        if centerValue > leftValue && centerValue > rightValue {
            let denominator = leftValue - 2 * centerValue + rightValue
            if denominator != 0 {
                interpolatedPeakIndex += ((leftValue - rightValue) / denominator) / 2
            }
        }
        return interpolatedPeakIndex
    }
}
