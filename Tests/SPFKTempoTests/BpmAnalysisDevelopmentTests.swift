import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKTempo

// MARK: - Local Tests on longer files not included in test resources

#if os(macOS)

@Suite(.tags(.file, .development))
class BpmAnalysisDevelopmentTests: TestCaseModel {
    /// Allow ±2 BPM tolerance for real-world audio detection due to lag quantization.
    private let bpmTolerance: Double = 2
    
    @Test func drumloop_110() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/110_drumloop.m4a")
        guard url.exists else { return }

        let bpm = try await BpmAnalysis(url: url).process()
        #expect(bpm?.isMultiple(of: 110, tolerance: bpmTolerance) == true)
    }

    @Test func drumloop_200() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/200_drumloop.m4a")
        guard url.exists else { return }

        let bpm = try await BpmAnalysis(url: url, options: .init(detection: .init(quality: .accurate))).process()
        #expect(bpm?.isMultiple(of: 200, tolerance: bpmTolerance) == true)
    }

    @Test func drumloop_75() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/75_wurli.m4a")

        guard url.exists else { return }

        let bpm = try await BpmAnalysis(url: url, options: .init(detection: .init(quality: .accurate))).process()
        #expect(bpm?.isMultiple(of: 75, tolerance: bpmTolerance) == true)
    }

    @Test func longSong() async throws {
        let url = URL(
            fileURLWithPath:
            "/Users/rf/Music/Music/Media.localized/Music/Aphex Twin/Drukqs Disc 01/07 Drukqs - Disk 01 - bbydhyonchord.mp3"
        )

        guard url.exists else { return }

        let ba = try BpmAnalysis(url: url, options: .init(detection: .init(quality: .fast))) { event in
            Log.debug(event.progress)
        }

        let bpm = try await ba.process()
        #expect(bpm?.isMultiple(of: 122, tolerance: bpmTolerance) == true)
    }

    @Test func cancelTask() async throws {
        let url = URL(
            fileURLWithPath:
            "/Users/rf/Music/Music/Media.localized/Music/Aphex Twin/Drukqs Disc 01/07 Drukqs - Disk 01 - bbydhyonchord.mp3"
        )

        guard url.exists else { return }

        let task = Task<Bpm?, Error>(priority: .high) {
            try await BpmAnalysis(url: url, options: .init(matchesRequired: 5)).process()
        }

        Task { @MainActor in
            try await Task.sleep(seconds: 1)
            task.cancel()
        }

        let result = await task.result
        Log.debug(result)

        #expect(task.isCancelled)
    }
}

#endif
