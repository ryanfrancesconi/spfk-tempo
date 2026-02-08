import Foundation
import SPFKAudioBase
import SPFKBase

public typealias BpmAnalysisEventHandler = @Sendable (BpmAnalysisEvent) async -> Void

public enum BpmAnalysisEvent: Sendable {
    case progress(url: URL, value: UnitInterval)
    case complete(url: URL, value: Bpm)

    public var progress: UnitInterval {
        switch self {
        case let .progress(url: _, value: progress):
            progress

        case .complete:
            1
        }
    }
}
