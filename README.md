# SPFKTempo
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)

A Swift package for detecting the tempo (BPM) of audio files using multi-band spectral flux analysis, FFT-based autocorrelation, and harmonic template matching. Built on the Accelerate framework with AVFoundation for audio decoding.

Supports any audio format readable by Core Audio and provides both a high-level async API with progress reporting and a low-level streaming API for real-time ingestion.

## Usage

### Detecting tempo from a file

```swift
import SPFKTempo

let bpm = try await BpmAnalysis(url: audioFileURL).process()
print("Detected: \(bpm)")  // "Detected: Bpm(120)"
```

### Handling short files

Files shorter than 7.5 seconds (half the default `minimumDuration` of 15) are automatically looped in-memory to provide enough material for stable detection:

```swift
// Explicit minimum duration — loops the file if shorter than half this value
let bpm = try await BpmAnalysis(url: shortFileURL, minimumDuration: 20).process()

// Disable looping
let bpm = try await BpmAnalysis(url: audioFileURL, minimumDuration: nil).process()
```

### Early exit with consensus voting

For long files, `matchesRequired` stops processing as soon as enough periodic estimates agree:

```swift
let analysis = try BpmAnalysis(
    url: audioFileURL,
    matchesRequired: 3,         // stop after 3 consistent estimates
    tolerance: 2.0,             // ±2 BPM counts as a match
    options: .init(
        quality: .accurate,     // 75% window overlap
        bpmRange: 60 ... 200    // constrain search range
    )
)

let bpm = try await analysis.process()
```

### Progress reporting and cancellation

```swift
let analysis = try BpmAnalysis(
    url: audioFileURL,
    matchesRequired: 3,
    options: .init(quality: .fast)
) { event in
    print("Progress: \(event.progress)")
}

let task = Task {
    try await analysis.process()
}

// Cancel after timeout
try await Task.sleep(for: .seconds(5))
task.cancel()
```

### Low-level streaming API

`BpmDetection` accepts raw samples directly for real-time or custom decoding pipelines:

```swift
let detector = BpmDetection(sampleRate: 48000, options: .init(quality: .balanced))

// Feed mono audio chunks as they arrive
for chunk in audioChunks {
    detector.process(chunk)
}

let bpm = detector.estimateTempo()         // top result
let candidates = detector.getTempoCandidates()  // ranked alternatives

// Reuse for another signal
detector.reset()
```

## Analysis Quality

| Quality | Overlap | Relative Speed | Best For |
|---------|---------|---------------|----------|
| `.fast` | None (1x) | ~4x faster | Strong rhythmic material, long files |
| `.balanced` | 50% (2x) | ~2x faster | General-purpose default |
| `.accurate` | 75% (4x) | Baseline | Complex material, short files |

## Configuration

`BpmDetection.Options` controls the algorithm behavior:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `quality` | `.balanced` | Window overlap level (see table above) |
| `bpmRange` | `40...300` | Valid tempo range — candidates outside are discarded |
| `beatsPerBar` | `4` | Beats per bar for comb-filter spacing (3 for waltz, etc.) |
| `perceptualWeightingAmount` | `0.0` | Mid-tempo bias strength (0.0 = neutral, 1.0 = full bias toward ~130 BPM) |

`BpmAnalysis` adds file-level parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `bufferDuration` | `1.0` | Duration in seconds of each analysis chunk |
| `minimumDuration` | `15` | Files shorter than half this are looped in-memory; `nil` to disable |
| `matchesRequired` | `nil` | Number of consistent periodic estimates for early exit; `nil` processes entire file |
| `tolerance` | `0` | BPM tolerance for consensus matching (0 = exact) |

## Architecture

```
BpmAnalysis (actor)
  |-- Wraps AVAudioFile + BpmDetection for file-level processing
  |-- AudioFileScanner feeds audio buffers in chunks
  |-- Periodic estimation with CountableResult consensus voting
  |-- Early cancellation when matchesRequired is satisfied
  |
  v
BpmDetection (class)
  |-- Streaming sample ingestion via process()
  |-- Overlapping analysis frames (blockSize / quality)
  |
  |-- FourierFilterbank (x3: low, mid, high bands)
  |     |-- Pre-computed windowed DFT basis (sin/cos tables)
  |     |-- vDSP matrix-vector multiply for per-band magnitude spectra
  |
  |-- Spectral Flux
  |     |-- Log-compressed positive flux per band
  |     |-- RMS energy envelope as broadband signal
  |     |-- Moving-average normalization to reduce loudness bias
  |
  |-- AutocorrelationFFT
  |     |-- FFT -> |X|^2 -> IFFT autocorrelation
  |     |-- Unity-normalized per-band, weighted sum across bands
  |
  |-- ACFCombFilter
  |     |-- Comb filtering at beat/bar multiples
  |     |-- Harmonic template scoring with octave-error penalties
  |     |-- Optional perceptual weighting toward mid-tempo
  |     |-- Parabolic interpolation for sub-lag peak refinement
  |
  v
Bpm (value type, typically 40-300 range)
```

### Processing Pipeline

1. **Input** — Audio samples arrive via `process()` (streaming) or `estimateTempoOfSamples()` (batch)
2. **Band decomposition** — Three `FourierFilterbank` instances extract magnitude spectra for low (0-550 Hz), mid (550-4000 Hz), and high (4-16 kHz) bands
3. **Onset detection** — Positive spectral flux (log-compressed, half-wave rectified) per band, plus a broadband RMS envelope, normalized by a moving average window to reduce loudness bias
4. **Periodicity analysis** — FFT-based autocorrelation, unity-normalized per band, then weighted-summed (low 1.0, mid 0.8, high 0.5, RMS 0.1)
5. **Candidate scoring** — ACF comb filter at beat/bar multiples, blended with harmonic template matching (rewards correct harmonics, penalizes octave errors)
6. **Peak refinement** — Parabolic interpolation for sub-lag precision, then conversion to BPM
7. **Consensus** (BpmAnalysis only) — `CountableResult` collects periodic estimates and triggers early exit when enough agree

## Supported Formats

Any audio format readable by Core Audio's `AVAudioFile`, including WAV, AIF, FLAC, M4A, MP4, MP3, AAC, CAF, and OGG.

## Dependencies

| Package | Purpose |
|---------|---------|
| [spfk-audio-base](https://github.com/ryanfrancesconi/spfk-audio-base) | `Bpm`, `AudioFileScanner`, `CountableResult`, `URLProgressEvent` |
| [spfk-testing](https://github.com/ryanfrancesconi/spfk-testing) | Test audio resources (test target only) |

## Requirements

- macOS 12+ / iOS 15+
- Swift 6.2+

## About

Spongefork (SPFK) is the personal software projects of [Ryan Francesconi](https://github.com/ryanfrancesconi). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2016 to 2025 he was the lead macOS developer at [Audio Design Desk](https://add.app).
