# SPFKTempo
[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-tempo)](https://github.com/ryanfrancesconi/spfk-tempo/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)

A Swift package for detecting the tempo (BPM) of audio files using multi-band spectral flux analysis, FFT-based autocorrelation, and harmonic template matching. Built on the Accelerate framework with AVFoundation for audio decoding.

Supports any audio format readable by Core Audio and provides both a high-level async API with progress reporting and a low-level streaming API for real-time ingestion.

## Detecting tempo

`BpmAnalysis` is an actor that reads a file and returns a `Bpm`. It reports progress and honors cancellation, and
takes a `BpmAnalysisOptions` carrying both file-level parameters and the detection options nested
inside it.

Files shorter than 7.5 seconds — half the default `minimumDuration` of 15 — are automatically looped
in memory to provide enough material for stable detection.

Processing stops as soon as 3 consistent periodic estimates agree within ±1 BPM. `matchesRequired`
and `tolerance` tighten or loosen that consensus.

`BpmDetection` is the low-level entry point, accepting raw samples directly for a real-time or
custom decoding pipeline.

## Analysis Quality

| Quality | Overlap | Relative Speed | Best For |
|---------|---------|---------------|----------|
| `.fast` | None (1x) | ~4x faster | Strong rhythmic material, long files |
| `.balanced` | 50% (2x) | ~2x faster | General-purpose default |
| `.accurate` | 75% (4x) | Baseline | Complex material, short files |

## Configuration

`BpmDetectionOptions` controls the algorithm behavior:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `quality` | `.balanced` | Window overlap level (see table above) |
| `bpmRange` | `40...300` | Valid tempo range — candidates outside are discarded |
| `beatsPerBar` | `4` | Beats per bar for comb-filter spacing (3 for waltz, etc.) |
| `perceptualWeightingAmount` | `0.0` | Mid-tempo bias strength (0.0 = neutral, 1.0 = full bias toward ~130 BPM) |
| `confidenceLevel` | `.moderate` | How aggressively to reject non-rhythmic audio (`.disabled`, `.low`, `.moderate`, `.high`) |

`BpmAnalysisOptions` wraps file-level parameters and a nested `detection` property:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `bufferDuration` | `1.0` | Duration in seconds of each analysis chunk |
| `minimumDuration` | `15` | Files shorter than half this are looped in-memory; `nil` to disable |
| `matchesRequired` | `3` | Number of consistent periodic estimates for early exit; `nil` processes entire file |
| `tolerance` | `1` | BPM tolerance for consensus matching (±1 BPM accommodates lag quantization jitter) |
| `detection` | `.init()` | Nested `BpmDetectionOptions` (see table above) |

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

- **Platforms:** macOS 13+, iOS 16+
- **Swift:** 6.2+

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
