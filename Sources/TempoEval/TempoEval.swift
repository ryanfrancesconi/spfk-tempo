// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

import AVFoundation
import Foundation
import SPFKAudioBase
import SPFKTempo

// Scores `BpmAnalysis` against labeled audio and times it per file. An executable, not a test
// suite: the timings only mean anything compiled `-O`.
//
// Build and run from the package directory:
//   swift build -c release
//   .build/release/spfk-tempo-eval <labels.tsv>... [options] [--out results.tsv]
//
// A labels file is tab-separated `path  label  group`, paths relative to the file, `#` comments.
// A label is one tempo (`120`), two tempi and the first's weight (`127 139 0.95`, the MIREX form),
// or `none`.
//
// Options mirror what ShadowTag's Detect Tempo builds from its dialog (`DetectTempoOptions`):
//   --quality fast|balanced|accurate   --min 40 --max 300 (the octave fold range)   --decimals 0
// and expose what the dialog cannot change:
//   --search-min 40 --search-max 300 (the engine's range)   --no-loop   --matches 3
//   --confidence disabled|low|moderate|high   --prior 0 (the engine's mid-tempo weighting, 0-1)
//
// Scores, per file, over the single tempo the public API returns:
//   acc1   |estimate - reference| <= 4 % of the reference (madmom's TOLERANCE, ISMIR 2004)
//   acc2   acc1 against the reference at 1/3, 1/2, 1, 2 and 3 times (madmom DOUBLE and TRIPLE)
//   pscore mir_eval's `tempo.detection` at 8 %: weight * hit(T1) + (1 - weight) * hit(T2), only
//          for a two-tempo label; `one` and `both` beside it
// The reference for acc1 and acc2 is the stronger tempo of a two-tempo label (madmom sorts by
// strength, keeping T1 on a tie). `--self-test` checks the scorer against those rules.

enum Label {
    case tempo(Double)
    case two(Double, Double, weight: Double)
    case none

    init?(_ text: String) {
        let parts = text.split(separator: " ").compactMap { Double($0) }

        switch (text, parts.count) {
        case ("none", _):
            self = .none
        case (_, 1) where parts[0] > 0:
            self = .tempo(parts[0])
        case (_, 3) where parts[0] >= 0 && parts[1] >= 0 && parts[0] + parts[1] > 0 && (0 ... 1).contains(parts[2]):
            // A second tempo of 0 means there is none (mir_eval's own rule; GiantSteps writes `134.0 0.0 1.0`).
            self = .two(parts[0], parts[1], weight: parts[2])
        default:
            return nil
        }
    }

    /// The tempo accuracy 1 and 2 are measured against: the stronger of two, ignoring a zero.
    var reference: Double? {
        switch self {
        case let .tempo(value): value
        case let .two(first, second, weight):
            if first == 0 { second } else if second == 0 { first } else { weight >= 0.5 ? first : second }
        case .none: nil
        }
    }
}

enum Outcome {
    case tempo(Double)
    case noTempo
    case failed(String)

    var text: String {
        switch self {
        case let .tempo(value): String(value)
        case .noTempo: "nil"
        case let .failed(reason): "throw:\(reason)"
        }
    }
}

enum Relationship: String, CaseIterable {
    case hit, octave, miss, noTempo, thrown
    case rejected, falseTempo, noneThrown
}

struct Score {
    let relationship: Relationship
    let acc1: Bool
    let acc2: Bool
    /// mir_eval's P-score, one-correct and both-correct; nil unless the label has two tempi.
    let pscore: (value: Double, one: Bool, both: Bool)?
    /// Signed error in percent of the reference, for an acc1 hit.
    let errorPercent: Double?
}

func within(_ estimate: Double, _ reference: Double, tolerance: Double) -> Bool {
    abs(estimate - reference) <= tolerance * reference
}

func score(label: Label, outcome: Outcome) -> Score {
    let none = Score(relationship: .rejected, acc1: false, acc2: false, pscore: nil, errorPercent: nil)

    switch (label, outcome) {
    case (.none, .noTempo):
        return none
    case (.none, .tempo):
        return Score(relationship: .falseTempo, acc1: false, acc2: false, pscore: nil, errorPercent: nil)
    case (.none, .failed):
        return Score(relationship: .noneThrown, acc1: false, acc2: false, pscore: nil, errorPercent: nil)
    case (_, .noTempo):
        return Score(relationship: .noTempo, acc1: false, acc2: false, pscore: zeroPScore(label), errorPercent: nil)
    case (_, .failed):
        return Score(relationship: .thrown, acc1: false, acc2: false, pscore: zeroPScore(label), errorPercent: nil)
    case let (_, .tempo(estimate)):
        guard let reference = label.reference else { return none }

        let acc1 = within(estimate, reference, tolerance: 0.04)
        let acc2 = [1.0, 2.0, 0.5, 3.0, 1.0 / 3.0].contains { within(estimate, reference * $0, tolerance: 0.04) }

        var pscore: (Double, Bool, Bool)?
        if case let .two(first, second, weight) = label {
            let hits = (first > 0 && within(estimate, first, tolerance: 0.08), second > 0 && within(estimate, second, tolerance: 0.08))
            pscore = (weight * (hits.0 ? 1 : 0) + (1 - weight) * (hits.1 ? 1 : 0), hits.0 || hits.1, hits.0 && hits.1)
        }

        return Score(
            relationship: acc1 ? .hit : (acc2 ? .octave : .miss),
            acc1: acc1,
            acc2: acc2,
            pscore: pscore,
            errorPercent: acc1 ? 100 * (estimate - reference) / reference : nil
        )
    }
}

func zeroPScore(_ label: Label) -> (value: Double, one: Bool, both: Bool)? {
    if case .two = label { return (0, false, false) }
    return nil
}

// MARK: - Cases

struct Settings {
    var quality: AnalysisQuality = .balanced
    var minBPM: Float = 40
    var maxBPM: Float = 300
    var decimals = 0
    var searchRange: ClosedRange<Float> = 40 ... 300
    var loops = true
    var matchesRequired: Int? = 3
    var confidence: ConfidenceLevel = .moderate
    var prior: Float = 0

    /// `DetectTempoOptions.bpmAnalysisOptions` (spfk-processing), with the engine settings it leaves at
    /// their defaults exposed.
    var analysisOptions: BpmAnalysisOptions {
        let lo = min(minBPM, maxBPM - 10)
        let hi = max(maxBPM, minBPM + 10)
        return BpmAnalysisOptions(
            minimumDuration: loops ? 15 : nil,
            matchesRequired: matchesRequired,
            detection: .init(quality: quality, bpmRange: searchRange, perceptualWeightingAmount: prior, confidenceLevel: confidence),
            preferredRange: lo ... hi,
            outputDecimalPlaces: decimals
        )
    }

    var description: String {
        "quality=\(quality) fold=\(minBPM)-\(maxBPM) search=\(searchRange.lowerBound)-\(searchRange.upperBound) "
            + "decimals=\(decimals) loop=\(loops) matches=\(matchesRequired.map(String.init) ?? "all") confidence=\(confidence) prior=\(prior)"
    }
}

struct Case {
    let url: URL
    let group: String
    let label: Label
    let labelText: String
}

struct Row {
    let item: Case
    let outcome: Outcome
    let score: Score
    let seconds: Double
    let duration: Double
}

func loadCases(from file: URL) throws -> [Case] {
    let base = file.deletingLastPathComponent()
    let text = try String(contentsOf: file, encoding: .utf8)
    var cases: [Case] = []

    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        let columns = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count >= 2 else {
            throw NSError(domain: "eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(file.lastPathComponent):\(index + 1): expected path<TAB>label[<TAB>group]"])
        }

        let path = columns[0]
        let labelText = columns[1].trimmingCharacters(in: .whitespaces)

        guard let label = Label(labelText) else {
            throw NSError(domain: "eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(file.lastPathComponent):\(index + 1): unreadable label '\(labelText)'"])
        }

        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        let group = columns.count > 2 ? columns[2] : file.deletingPathExtension().lastPathComponent
        cases.append(Case(url: url, group: group, label: label, labelText: labelText))
    }

    return cases
}

func evaluate(_ item: Case, settings: Settings) async -> Row {
    let clock = ContinuousClock()
    var duration = 0.0
    var outcome: Outcome = .failed("error")

    let elapsed = await clock.measure {
        do {
            let file = try AVAudioFile(forReading: item.url)
            duration = Double(file.length) / file.processingFormat.sampleRate

            let analysis = BpmAnalysis(audioFile: file, options: settings.analysisOptions)
            outcome = try await analysis.process().map { .tempo($0.rawValue) } ?? .noTempo
        } catch {
            outcome = .failed(error.localizedDescription.replacingOccurrences(of: "\t", with: " "))
            FileHandle.standardError.write(Data("\(item.url.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }

    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    return Row(item: item, outcome: outcome, score: score(label: item.label, outcome: outcome), seconds: seconds, duration: duration)
}

// MARK: - Reporting

func percent(_ numerator: Int, _ denominator: Int) -> String {
    denominator == 0 ? "-" : String(format: "%.1f%%", 100 * Double(numerator) / Double(denominator))
}

func summarize(_ rows: [Row], title: String) -> String {
    let n = rows.count
    guard n > 0 else { return "" }

    let labeled = rows.filter { if case .none = $0.item.label { return false } else { return true } }
    let unlabeled = rows.filter { if case .none = $0.item.label { return true } else { return false } }
    let acc1 = labeled.filter(\.score.acc1).count
    let acc2 = labeled.filter(\.score.acc2).count

    var counts: [Relationship: Int] = [:]
    for row in rows { counts[row.score.relationship, default: 0] += 1 }

    var out = "\(title): n=\(n)"
    if !labeled.isEmpty {
        out += " acc1=\(acc1)/\(labeled.count) (\(percent(acc1, labeled.count))) acc2=\(acc2)/\(labeled.count) (\(percent(acc2, labeled.count)))"
    }
    let scored = rows.compactMap(\.score.pscore)
    if !scored.isEmpty {
        let mean = scored.map(\.value).reduce(0, +) / Double(scored.count)
        out += String(format: " pscore=%.3f one=%@ both=%@", mean,
                      percent(scored.filter(\.one).count, scored.count), percent(scored.filter(\.both).count, scored.count))
    }
    if !unlabeled.isEmpty {
        out += " rejected=\(percent(counts[.rejected, default: 0], unlabeled.count)) falseTempo=\(percent(counts[.falseTempo, default: 0], unlabeled.count))"
    }

    out += "\n    " + Relationship.allCases.compactMap { rel in counts[rel].map { "\(rel.rawValue)=\($0)" } }.joined(separator: " ")

    let errors = rows.compactMap(\.score.errorPercent)
    if !errors.isEmpty {
        let mean = errors.reduce(0, +) / Double(errors.count)
        let absMean = errors.map(abs).reduce(0, +) / Double(errors.count)
        out += String(format: "\n    error over hits: mean %+.2f%%, mean |error| %.2f%%, max |error| %.2f%%", mean, absMean, errors.map(abs).max() ?? 0)
    }

    let totalSeconds = rows.map(\.seconds).reduce(0, +)
    let totalAudio = rows.map(\.duration).reduce(0, +)
    let sorted = rows.map(\.seconds).sorted()
    out += String(
        format: "\n    time: mean %.1f ms/file, median %.1f ms/file, %.2f ms per audio second, total %.2f s",
        1000 * totalSeconds / Double(n), 1000 * sorted[sorted.count / 2],
        totalAudio > 0 ? 1000 * totalSeconds / totalAudio : 0, totalSeconds
    )
    return out
}

func writeResults(_ rows: [Row], to url: URL) throws {
    var text = "path\tgroup\tlabel\toutcome\trelationship\tacc1\tacc2\tpscore\tone\tboth\terror_pct\tms\tduration\n"
    for row in rows {
        let p = row.score.pscore
        text += [
            row.item.url.path, row.item.group, row.item.labelText, row.outcome.text,
            row.score.relationship.rawValue, row.score.acc1 ? "1" : "0", row.score.acc2 ? "1" : "0",
            p.map { String(format: "%.6f", $0.value) } ?? "", p.map { $0.one ? "1" : "0" } ?? "", p.map { $0.both ? "1" : "0" } ?? "",
            row.score.errorPercent.map { String(format: "%.4f", $0) } ?? "",
            String(format: "%.2f", 1000 * row.seconds), String(format: "%.3f", row.duration),
        ].joined(separator: "\t") + "\n"
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Self test

func selfTest() -> Bool {
    // (label, estimate, acc1, acc2, pscore) from madmom's tempo_evaluation (4 %, double and triple)
    // and mir_eval's tempo.detection (8 %).
    let table: [(String, Double, Bool, Bool, Double?)] = [
        ("120", 120, true, true, nil),
        ("120", 124.8, true, true, nil),
        ("120", 115.2, true, true, nil),
        ("120", 125, false, false, nil),
        ("120", 60, false, true, nil),
        ("120", 240, false, true, nil),
        ("120", 40, false, true, nil),
        ("120", 360, false, true, nil),
        ("120", 180, false, false, nil),
        ("120", 90, false, false, nil),
        ("62.5", 125, false, true, nil),
        ("127 139 0.9487", 127, true, true, 0.9487),
        ("127 139 0.9487", 139, false, false, 0.0513),
        ("127 139 0.9487", 133, false, false, 1),
        ("100 200 0.4", 200, true, true, 0.6),
        ("100 200 0.4", 100, false, true, 0.4),
        ("100 200 0.5", 100, true, true, 0.5),
        ("134 0 1", 134, true, true, 1),
        ("134 0 1", 268, false, true, 0),
    ]

    var ok = true
    for (labelText, estimate, acc1, acc2, pscore) in table {
        guard let label = Label(labelText) else { print("self-test FAILED: unreadable '\(labelText)'"); ok = false; continue }
        let s = score(label: label, outcome: .tempo(estimate))
        let pscoreOK = (s.pscore?.value).map { abs($0 - (pscore ?? -1)) < 1e-9 } ?? (pscore == nil)
        if s.acc1 != acc1 || s.acc2 != acc2 || !pscoreOK {
            print("self-test FAILED: \(labelText) -> \(estimate) gave acc1=\(s.acc1) acc2=\(s.acc2) pscore=\(String(describing: s.pscore?.value)), expected (\(acc1), \(acc2), \(String(describing: pscore)))")
            ok = false
        }
    }

    let checks: [(Label, Outcome, Relationship)] = [
        (.none, .noTempo, .rejected), (.none, .tempo(120), .falseTempo), (.none, .failed("x"), .noneThrown),
        (.tempo(120), .noTempo, .noTempo), (.tempo(120), .failed("x"), .thrown),
        (.tempo(120), .tempo(60), .octave), (.tempo(120), .tempo(121), .hit), (.tempo(120), .tempo(90), .miss),
    ]
    for (label, outcome, expected) in checks where score(label: label, outcome: outcome).relationship != expected {
        print("self-test FAILED: \(label) -> \(outcome.text) expected \(expected.rawValue)")
        ok = false
    }
    if let p = score(label: Label("127 139 0.9")!, outcome: .noTempo).pscore, p.value != 0 || p.one || p.both { ok = false }

    print(ok ? "self-test passed (\(table.count + checks.count + 1) cases)" : "self-test FAILED")
    return ok
}

// MARK: - Main

@main
struct TempoEval {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var settings = Settings()
        var outURL: URL?
        var labelFiles: [URL] = []

        func next() -> String { arguments.isEmpty ? "" : arguments.removeFirst() }

        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--self-test":
                exit(selfTest() ? 0 : 1)
            case "--quality":
                switch next() {
                case "fast": settings.quality = .fast
                case "balanced": settings.quality = .balanced
                case "accurate": settings.quality = .accurate
                default: print("--quality takes fast, balanced or accurate"); exit(2)
                }
            case "--min": settings.minBPM = Float(next()) ?? settings.minBPM
            case "--max": settings.maxBPM = Float(next()) ?? settings.maxBPM
            case "--decimals": settings.decimals = Int(next()) ?? settings.decimals
            case "--search-min": settings.searchRange = (Float(next()) ?? settings.searchRange.lowerBound) ... settings.searchRange.upperBound
            case "--search-max": settings.searchRange = settings.searchRange.lowerBound ... (Float(next()) ?? settings.searchRange.upperBound)
            case "--no-loop": settings.loops = false
            case "--matches":
                let value = next()
                settings.matchesRequired = value == "all" ? nil : (Int(value) ?? settings.matchesRequired)
            case "--confidence":
                switch next() {
                case "disabled": settings.confidence = .disabled
                case "low": settings.confidence = .low
                case "moderate": settings.confidence = .moderate
                case "high": settings.confidence = .high
                default: print("--confidence takes disabled, low, moderate or high"); exit(2)
                }
            case "--prior": settings.prior = Float(next()) ?? settings.prior
            case "--out":
                outURL = URL(fileURLWithPath: next())
            default:
                labelFiles.append(URL(fileURLWithPath: argument))
            }
        }

        guard !labelFiles.isEmpty else {
            print("usage: spfk-tempo-eval <labels.tsv>... [--quality balanced] [--min 40 --max 300] [--decimals 0] [--search-min 40 --search-max 300] [--no-loop] [--matches 3|all] [--confidence moderate] [--prior 0] [--out results.tsv] [--self-test]")
            exit(2)
        }

        let cases = try labelFiles.flatMap(loadCases(from:))
        print("\(settings.description) files=\(cases.count)")

        var rows: [Row] = []
        rows.reserveCapacity(cases.count)

        for (index, item) in cases.enumerated() {
            rows.append(await evaluate(item, settings: settings))
            if (index + 1) % 100 == 0 {
                FileHandle.standardError.write(Data("  \(index + 1)/\(cases.count)\n".utf8))
            }
        }

        let groups = Dictionary(grouping: rows, by: \.item.group)
        for group in groups.keys.sorted() {
            print(summarize(groups[group] ?? [], title: group))
        }
        if groups.count > 1 {
            print(summarize(rows, title: "ALL"))
        }

        if let outURL {
            try writeResults(rows, to: outURL)
            print("wrote \(outURL.path)")
        }
    }
}
