import Foundation
import SPFKAudioBase
import SPFKBase
import SPFKTesting
import Testing

@testable import SPFKTempo

// MARK: - Local Tests on longer files not included in test resources

#if os(macOS)

    /// A folder of local audio files, named by `SPFK_DEVELOPMENT_RESOURCES`. Unset, these tests are disabled.
    private let developmentResources = ProcessInfo.processInfo.environment["SPFK_DEVELOPMENT_RESOURCES"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    @Suite(
        .tags(.file, .development, .slow),
        .enabled(if: developmentResources != nil, "Set SPFK_DEVELOPMENT_RESOURCES to a folder holding a bpm folder of loops")
    )
    class BpmAnalysisDevelopmentTests: TestCaseModel {
        private func resource(_ name: String) throws -> URL {
            let url = try #require(developmentResources).appendingPathComponent("bpm").appendingPathComponent(name)
            try #require(url.exists, "\(name) is missing from the bpm folder")
            return url
        }

        /// Allow ±2 BPM tolerance for real-world audio detection due to lag quantization.
        private let bpmTolerance: Double = 2

        @Test func drumstem_110() async throws {
            let url = try resource("110BPM_CONFUSION_DRUMSTEM_1.m4a")

            let options = BpmAnalysisOptions(preferredRange: 60 ... 180)
            let bpm = try await BpmAnalysis(url: url, options: options).process()
            #expect(bpm?.rawValue == 110)
        }

        @Test func drumloop_110() async throws {
            let url = try resource("110_drumloop.m4a")

            let bpm = try await BpmAnalysis(url: url).process()
            #expect(bpm?.rawValue == 110)
        }

        @Test func drumloop_125() async throws {
            let url = try resource("LP Hat Loop 15 125BPM.wav")

            let bpm = try await BpmAnalysis(url: url, options: .init(detection: .init(quality: .accurate))).process()
            #expect(bpm?.rawValue == 125)
        }

        @Test func drumloop_200() async throws {
            let url = try resource("200_drumloop.m4a")

            let bpm = try await BpmAnalysis(url: url, options: .init(detection: .init(quality: .accurate), preferredRange: nil)).process()
            #expect(bpm?.isMultiple(of: 200, tolerance: 2) == true)
        }

        @Test func drumloop_75() async throws {
            let url = try resource("75_wurli.m4a")

            let bpm = try await BpmAnalysis(url: url, options: .init(detection: .init(quality: .accurate))).process()
            #expect(bpm?.isMultiple(of: 75, tolerance: bpmTolerance) == true)
        }

        @Test func longSong() async throws {
            let url = try resource("07 Drukqs - Disk 01 - bbydhyonchord.mp3")

            let ba = try BpmAnalysis(url: url, options: .init(detection: .init(quality: .fast))) { event in
                Log.debug(event.progress)
            }

            let bpm = try await ba.process()
            #expect(bpm?.rawValue == 123)
        }

        @Test func cancelTask() async throws {
            let url = try resource("07 Drukqs - Disk 01 - bbydhyonchord.mp3")

            let task = Task<Bpm?, Error>(priority: .high) {
                try await BpmAnalysis(url: url, options: .init(matchesRequired: 5)).process()
            }

            Task { @MainActor in
                try? await Task.sleep(seconds: 0.5)
                task.cancel()
            }

            let result = await task.result
            Log.debug(result)

            #expect(task.isCancelled)
        }
    }

#endif
