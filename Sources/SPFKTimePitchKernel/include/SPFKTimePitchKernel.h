// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

#ifndef SPFKTimePitchKernel_h
#define SPFKTimePitchKernel_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A Signalsmith Stretch instance, either live (block by block) or offline (`TimePitchKernelRenderExact`).
typedef struct TimePitchKernel *TimePitchKernelRef;

typedef enum {
    /// Signalsmith's `presetDefault`: 120 ms blocks, 30 ms interval.
    TimePitchKernelQualityBest = 0,
    /// Signalsmith's `presetCheaper`: 100 ms blocks, 40 ms interval.
    TimePitchKernelQualityEfficient = 1,
} TimePitchKernelQuality;

/// Output speed relative to the source; must equal `TimePitchDescription.rateRange`.
static const double kTimePitchMinRate = 0.5;
static const double kTimePitchMaxRate = 2.0;

/// How long a live kernel takes to move to a new rate, linearly, in output seconds.
static const double kTimePitchRateRampSeconds = 0.02;

/// Seeds the phase randomization, so an offline render of the same input and settings is bit-identical.
static const long kTimePitchSeed = 0x53504654;

/// `round(inputFrames / rate)`, rounding half away from zero like Swift's `.rounded()`.
int64_t TimePitchOutputFrameCount(int64_t inputFrames, double rate);

/// Allocates everything the kernel will use. Returns NULL for a channel count of 0 or a non-positive sample rate.
///
/// `live` turns on `splitComputation`, which spreads each block's FFT work across calls at the cost of
/// one more interval of output latency.
TimePitchKernelRef TimePitchKernelCreate(uint32_t channels, double sampleRate, uint32_t maxOutputFrames,
                                         TimePitchKernelQuality quality, bool live);
void TimePitchKernelDestroy(TimePitchKernelRef kernel);

/// Thread-safe. `rate` is clamped into the supported range. A live kernel ramps to a new rate over
/// `kTimePitchRateRampSeconds`.
void TimePitchKernelSetTargets(TimePitchKernelRef kernel, double rate, double transposeFactor);

/// Thread-safe. A tonality limit of 0 is off and a formant base of 0 is automatic detection.
void TimePitchKernelSetTimbre(TimePitchKernelRef kernel, double tonalityLimitHz, double formantSemitones,
                              bool formantCorrection, double formantBaseHz);

/// Render thread only. Begins a block: applies pending settings and a pending reset, advances the
/// rate ramp, and returns the input frames to pull for `outputFrames` of output. Over any run the
/// total input is the rounded sum of each block's output × rate.
uint32_t TimePitchKernelInputFramesNeeded(TimePitchKernelRef kernel, uint32_t outputFrames);

/// Render thread only. Returns false, writing nothing, when `outputFrames` exceeds the create-time maximum.
bool TimePitchKernelProcess(TimePitchKernelRef kernel, const float *const *input, uint32_t inputFrames,
                            float *const *output, uint32_t outputFrames);

/// Thread-safe. The render thread resets the kernel at the start of its next block.
void TimePitchKernelReset(TimePitchKernelRef kernel);

/// Source frames between the newest input and the kernel's analysis position.
int32_t TimePitchKernelInputLatencyFrames(TimePitchKernelRef kernel);
/// Output frames between the kernel's synthesis position and what it returns.
int32_t TimePitchKernelOutputLatencyFrames(TimePitchKernelRef kernel);
/// The time from a source frame entering a live kernel to its being returned, at a constant `rate`.
double TimePitchKernelLatencySeconds(TimePitchKernelRef kernel, double rate);

/// Every input frame passed to `TimePitchKernelProcess` since create.
int64_t TimePitchKernelSourceFramesConsumed(TimePitchKernelRef kernel);

/// The source frames `TimePitchKernelRenderExact` reads before and after the material at `rate`.
/// Frames the file does not have are read as silence.
void TimePitchKernelContextFrames(TimePitchKernelRef kernel, double rate, int64_t *preContext, int64_t *postContext);

/// Offline only. Renders `inputFrames` of material to exactly `outputFrames`, using the current targets.
///
/// Each `input` channel points at the first material frame, with `preContext` readable frames before it
/// and `postContext` after the last. Fails, writing nothing, unless
/// `outputFrames == TimePitchOutputFrameCount(inputFrames, rate)`.
bool TimePitchKernelRenderExact(TimePitchKernelRef kernel, const float *const *input, int64_t inputFrames,
                                int64_t preContext, int64_t postContext, float *const *output, int64_t outputFrames);

#ifdef __cplusplus
}
#endif

#endif /* SPFKTimePitchKernel_h */
