# SPFKTempo
[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-tempo)](https://github.com/ryanfrancesconi/spfk-tempo/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-tempo%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-tempo)

Two ways of working with an audio file's time: detecting its tempo, and changing its rate and pitch
independently of each other.

## Tempo detection

Detection looks for a steady pulse rather than for individual beats. It measures how the spectrum
changes over time in several frequency bands, finds the periods at which those changes repeat, and
scores candidate tempos against the beat and bar structure that period implies. Tempo is
ambiguous by an octave by nature — a track at 140 BPM is also a track at 70 — so the result is
chosen within a family of related tempos rather than taken as the strongest single peak.

Material with no steady pulse comes back as `nil` rather than as a confident guess. A drone, a
dialogue line or a sound effect has no tempo, and a tagging app is better served by an empty field
than by a wrong one.

```swift
let bpm: Bpm? = try await BpmAnalysis(url: url).process()
```

`BpmAnalysis` reads any file Core Audio can open, reports progress, honors cancellation, and stops
early once successive estimates agree. Very short files, such as a one-bar loop, are repeated in
memory so there is enough material to measure.

`BpmDetection` is the same engine without the file: feed it samples as they arrive and ask for an
estimate when you need one, for a live input or a decoder of your own.

## Time and pitch

`SPFKTimePitchKernel` is a C interface over the vendored
[Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) (MIT), so a caller
needs no Swift/C++ interop. It runs in two modes:

- **Live**, block by block, where every allocation happens up front and the rate and pitch can be
  changed from any thread while the render thread runs.
- **Offline**, where a render produces exactly the length the rate implies, reading real audio past
  each edge of the selection where the file has it, and fails rather than return a different length.

`TimePitchRenderer` is the Swift entry point to the offline mode. It throws rather than hand back
silence from an input that was not silent, so a failed render is never mistaken for a quiet one.

```swift
let shifted = try await TimePitchRenderer.render(
    buffer,
    description: TimePitchDescription(semitones: 7),
    quality: .best
)
```

## Scope

The shared audio types (`Bpm`, `TimePitchDescription`) come from spfk-audio-base.
Musical key detection is in spfk-musical-analysis. Everything here is analysis or rendering only,
with no UI.

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
