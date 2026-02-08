import Foundation
import SPFKBase

public typealias BpmAnalysisEventHandler = @Sendable (BpmAnalysisEvent) async -> Void

public enum BpmAnalysisEvent: Sendable {
    case loading(url: URL, progress: UnitInterval)
}
