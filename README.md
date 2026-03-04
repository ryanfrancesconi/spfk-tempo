# SPFKTempo

Pure Swift BPM detection library using multi-band spectral flux analysis, FFT-based autocorrelation, and harmonic template matching. Processes audio files via AVFoundation with early-exit support for streaming detection.

## Features

- Multi-band onset detection across low (0-550 Hz), mid (550-4000 Hz), and high (4-16 kHz) frequency ranges
- FFT-based autocorrelation with Accelerate framework for efficient periodicity analysis
- ACF comb filtering with harmonic template scoring to reduce octave errors
- Configurable analysis quality (fast/balanced/accurate) controlling window overlap
- Streaming API with early termination when consensus is reached
- Customizable BPM range, beats per bar, and perceptual weighting
- Optional tolerance-based matching for identifying tempo multiples (60/120/240)
- Async actor-based `BpmAnalysis` with progress reporting and cancellation support
- Pure Swift — no C++, Objective-C, or external DSP dependencies

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
  |     |-- FFT → |X|² → IFFT autocorrelation
  |     |-- Unity-normalized per-band, weighted sum across bands
  |
  |-- ACFCombFilter
  |     |-- Comb filtering at beat/bar multiples
  |     |-- Harmonic template scoring with octave-error penalties
  |     |-- Optional perceptual weighting toward mid-tempo
  |     |-- Parabolic interpolation for sub-lag peak refinement
  |
  v
Bpm (Double, 40-300 range)
```

## Usage

### Basic Detection

```swift
import SPFKTempo

let bpm = try await BpmAnalysis(url: audioFileURL).process()
print("Detected: \(bpm) BPM")
```

### With Options

```swift
let analysis = try BpmAnalysis(
    url: audioFileURL,
    matchesRequired: 3,         // early exit after 3 consensus matches
    tolerance: 2.0,             // ±2 BPM for tempo multiple matching
    options: .init(
        quality: .accurate,     // 75% overlap, highest precision
        bpmRange: 60 ... 200,   // constrain search range
        beatsPerBar: 4
    )
)

let bpm = try await analysis.process()
```

### Progress Reporting and Cancellation

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

### Low-Level Streaming API

```swift
let detector = BpmDetection(sampleRate: 48000, options: .init(quality: .balanced))

// Feed audio chunks as they arrive
for chunk in audioChunks {
    detector.process(chunk)
}

let bpm = detector.estimateTempo()
let candidates = detector.getTempoCandidates()
```

## Analysis Quality

| Quality | Overlap | Relative Speed | Best For |
|---------|---------|---------------|----------|
| `.fast` | None (1x) | ~4x faster | Strong rhythmic material, long files |
| `.balanced` | 50% (2x) | ~2x faster | General-purpose default |
| `.accurate` | 75% (4x) | Baseline | Complex material, short files |

## Dependencies

- **SPFKAudioBase** - Audio type definitions (`Bpm`, `AudioFileScanner`)
- **SPFKUtils** - General utilities (`CountableResult`)

## Requirements

- macOS 12+ / iOS 15+
- Swift 6.2+
