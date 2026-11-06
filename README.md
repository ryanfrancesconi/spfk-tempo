# SPFKTempo
[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-tempo)](https://github.com/ryanfrancesconi/spfk-tempo/tags)
[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)

Tempo detection and time-stretching for audio files. Detection finds a steady pulse and returns its
BPM, or `nil` when the material has none. Time and pitch can be changed independently using a
vendored copy of [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch).

## Features

- Tempo detection from any file Core Audio can open (`BpmAnalysis`), with progress, cancellation
  and early exit once successive estimates agree
- Very short files, such as a one-bar loop, are repeated in memory so there is enough to measure
- A streaming detector (`BpmDetection`) that takes samples as they arrive, for live input or a
  custom decoder
- Offline time and pitch rendering of a buffer (`TimePitchRenderer`)
- A C interface to the stretcher (`SPFKTimePitchKernel`) for real-time use, with settings that can
  change from any thread while the render thread runs

## Usage

```swift
let bpm: Bpm? = try await BpmAnalysis(url: url).process()
```

```swift
let shifted = try await TimePitchRenderer.render(
    buffer,
    description: TimePitchDescription(semitones: 7),
    quality: .best
)
```

## Notes

- Tempo is ambiguous by an octave: a track at 140 BPM is also a track at 70. The result is chosen
  within a family of related tempos, not taken as the single strongest peak.
- Material with no steady pulse, such as a drone, dialogue or a sound effect, returns `nil`.
- `TimePitchRenderer.render` produces exactly the length the rate implies, and throws rather than
  return silence from input that was not silent.
- `Bpm` and `TimePitchDescription` come from
  [spfk-audio-base](https://github.com/ryanfrancesconi/spfk-audio-base).

## License

Signalsmith Stretch is included under its MIT license.

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
