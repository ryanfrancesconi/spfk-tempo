import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKTempo

@Suite(.tags(.file))
class BpmAnalysisTests: TestCaseModel {
    /// Allow ±2 BPM tolerance for real-world audio detection due to lag quantization.
    private let bpmTolerance: Double = 2

    @Test func drumloop_60() async throws {
        let url = TestBundleResources.shared.counting_123456789_60BPM_48k
        let bpm = try await BpmAnalysis(url: url).process()
        #expect(bpm.isMultiple(of: 60, tolerance: bpmTolerance))
    }

    @Test func drumloop_110() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/110_drumloop.m4a")
        let bpm = try await BpmAnalysis(url: url).process()
        #expect(bpm.isMultiple(of: 110, tolerance: bpmTolerance))
    }

    @Test func tabla_109() async throws {
        let url = TestBundleResources.shared.tabla_wav
        let bpm = try await BpmAnalysis(url: url, options: .init(quality: .accurate)).process()
        #expect(bpm.isMultiple(of: 109, tolerance: bpmTolerance))
    }

    @Test func drumloop_200() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/200_drumloop.m4a")
        let bpm = try await BpmAnalysis(url: url, options: .init(quality: .accurate)).process()
        #expect(bpm.isMultiple(of: 200, tolerance: bpmTolerance))
    }

    @Test func drumloop_75() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/75_wurli.m4a")
        let bpm = try await BpmAnalysis(url: url, options: .init(quality: .accurate)).process()
        #expect(bpm.isMultiple(of: 75, tolerance: bpmTolerance))
    }

    @Test func longSong() async throws {
        let url = URL(
            fileURLWithPath:
            "/Users/rf/Music/Music/Media.localized/Music/Aphex Twin/Drukqs Disc 01/07 Drukqs - Disk 01 - bbydhyonchord.mp3"
        )

        let ba = try BpmAnalysis(url: url, matchesRequired: 3, options: .init(quality: .fast)) { event in
            Log.debug(event.progress)
        }

        let bpm = try await ba.process()
        #expect(bpm.isMultiple(of: 122, tolerance: bpmTolerance))
    }

    @Test func cancelTask() async throws {
        let url = URL(
            fileURLWithPath:
            "/Users/rf/Music/Music/Media.localized/Music/Aphex Twin/Drukqs Disc 01/07 Drukqs - Disk 01 - bbydhyonchord.mp3"
        )

        let task = Task<Bpm, Error>(priority: .high) {
            try await BpmAnalysis(url: url, matchesRequired: 5).process()
        }

        Task { @MainActor in
            try await Task.sleep(seconds: 1)
            task.cancel()
        }

        let result = await task.result
        Log.debug(result)

        let bpm = try #require(result.successValue)

        #expect(bpm.isMultiple(of: 122, tolerance: bpmTolerance))
    }

    /// Tabla is ~4.39s, well under the 7.5s looping threshold (minimumDuration=15).
    /// This verifies that AudioFileScanner's in-memory looping produces enough
    /// material for BPM detection without creating temp files on disk.
    @Test func shortFile_tabla() async throws {
        let url = TestBundleResources.shared.tabla_wav
        let bpm = try await BpmAnalysis(url: url, minimumDuration: 15).process()
        #expect(bpm.isMultiple(of: 109, tolerance: bpmTolerance))
    }

    @Test func mostLikely() async throws {
        let list: CountableResult<Bpm> = [
            Bpm(1)!,
            Bpm(2)!,
            Bpm(2)!,
            Bpm(3)!
        ]

        let result: Bpm = list.choose()!

        #expect(result == Bpm(2))
    }
}
