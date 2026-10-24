# Vendored: Signalsmith Stretch

Header-only, MIT. Each library's license is beside it.

| Library | Version | Commit |
| --- | --- | --- |
| [signalsmith-stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) | 1.3.2 | `88061fd4eda56a2353c5d65c74aa3f4ccf76f9da` |
| [signalsmith-linear](https://github.com/Signalsmith-Audio/linear) | — | `7bb1c8f36794d6980080ce817c91f8da8fe56a66` |

`signalsmith-stretch.h` is the repository's root header. From `linear`, the root `approx.h`, `fft.h`, `linear.h` and `stft.h` sit under `signalsmith-linear/` (where the stretch header includes them from), with only the Accelerate and portable backends of `platform/`. The kernel compiles them with `SIGNALSMITH_USE_ACCELERATE`. Nothing is modified.
