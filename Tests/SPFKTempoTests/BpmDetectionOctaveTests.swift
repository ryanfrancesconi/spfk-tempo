import Foundation
import Testing

@testable import SPFKTempo

@Suite("BpmDetection octave choice")
struct BpmDetectionOctaveTests {
    /// Strong clicks on every beat and weak ones halfway between, so the half-beat period also
    /// repeats, less strongly: the beat level must win over its double.
    private static func makeAccentedClickTrack(bpm: Double, sampleRate: Double, durationSeconds: Double) -> [Float] {
        let sampleCount = Int(sampleRate * durationSeconds)
        let halfBeat = (60.0 / bpm / 2) * sampleRate
        let clickLength = Int(sampleRate * 0.012)
        var samples = [Float](repeating: 0, count: sampleCount)
        var index = 0
        var position = 0.0
        while Int(position) < sampleCount {
            let gain: Float = index % 2 == 0 ? 1 : 0.35
            for offset in 0 ..< clickLength {
                let at = Int(position) + offset
                if at >= sampleCount { break }
                samples[at] += gain * Float(exp(-Double(offset) / (sampleRate * 0.0025)))
            }
            index += 1
            position += halfBeat
        }
        return samples
    }

    @Test("The accented beat level wins over the weak half-beat level", arguments: [96.0, 120, 140])
    func beatLevelWinsOverHalfBeats(bpm: Double) {
        let sampleRate: Float = 44100
        let samples = Self.makeAccentedClickTrack(bpm: bpm, sampleRate: Double(sampleRate), durationSeconds: 30)
        let detector = BpmDetection(sampleRate: sampleRate)
        let tempo = detector.estimateTempoOfSamples(samples)
        #expect(abs(tempo - bpm) <= 0.04 * bpm, "expected \(bpm), got \(tempo)")
    }

    @Test("The prior is 1 at its center and falls off symmetrically in octaves")
    func priorShape() {
        let center = BpmDetection.Tuning.Prior.center
        #expect(BpmDetection.tempoPrior(center) == 1)
        let above = BpmDetection.tempoPrior(center * 2)
        let below = BpmDetection.tempoPrior(center / 2)
        #expect(abs(above - below) < 1e-5)
        #expect(above < 1)
        #expect(BpmDetection.tempoPrior(center * 4) < above)
    }
}
