import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKTempo

// TODO: utility to create tests files or add to SPFKTesting suitable samples

@Suite(.tags(.file))
class BpmAnalysisTests: TestCaseModel {
    @Test func drumloop_60() async throws {
        let url = TestBundleResources.shared.counting_123456789_60BPM_48k
        let bpm = try await BpmAnalysis(url: url).process()
        #expect(bpm.isMultiple(of: 60)) // 120
    }

    // Fails, returns 74
    @Test func drumloop_110() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/110_drumloop.m4a")
        let bpm = try await BpmAnalysis(url: url).process()
        #expect(bpm.isMultiple(of: 110)) // 74??
    }

    // Fails, returns 74
    @Test func tabla_109() async throws {
        let url = TestBundleResources.shared.tabla_wav
        let bpm = try await BpmAnalysis(url: url).process() // 74??
        #expect(bpm.isMultiple(of: 109))
    }

    @Test func drumloop_200() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/200_drumloop.m4a")
        let bpm = try await BpmAnalysis(url: url).process()
        #expect(bpm.isMultiple(of: 200)) // 100
    }

    @Test func drumloop_75() async throws {
        let url = URL(fileURLWithPath: "/Users/rf/Downloads/TestResources/bpm/75_wurli.m4a")
        let bpm = try await BpmAnalysis(url: url).process() // 150
        #expect(bpm.isMultiple(of: 75))
    }

    @Test func longSong() async throws {
        let url = URL(
            fileURLWithPath:
            "/Users/rf/Music/Music/Media.localized/Music/Aphex Twin/Drukqs Disc 01/07 Drukqs - Disk 01 - bbydhyonchord.mp3"
        )

        let ba = try BpmAnalysis(url: url, matchesRequired: 5) { event in
            Log.debug(event.progress)
        }

        let bpm = try await ba.process()
        #expect(bpm.isMultiple(of: 122))
    }

    @Test func cancelTask() async throws {
        let url = URL(
            fileURLWithPath:
            "/Users/rf/Music/Music/Media.localized/Music/Aphex Twin/Drukqs Disc 01/07 Drukqs - Disk 01 - bbydhyonchord.mp3"
        )

        let task = Task<Bpm, Error>(priority: .high) {
            try await BpmAnalysis(url: url, matchesRequired: 4).process()
        }

        Task { @MainActor in
            try await Task.sleep(seconds: 0.1)
            task.cancel()
        }

        let result = await task.result
        Log.debug(result)

        #expect(result.isSuccess)

        #expect(result.successValue == Bpm(61))
    }

    @Test func mostLikely() async throws {
        let list: CountableResult<Bpm> = [
            Bpm(1)!,
            Bpm(2)!,
            Bpm(2)!,
            Bpm(3)!
        ]

        let result: Bpm = list.mostLikely()!

        #expect(result == Bpm(2))
    }
}
