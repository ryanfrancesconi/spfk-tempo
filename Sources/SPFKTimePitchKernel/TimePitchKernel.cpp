// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

#include "SPFKTimePitchKernel.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#include "signalsmith-stretch/signalsmith-stretch.h"
#pragma clang diagnostic pop

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

namespace {

using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

/// Reads `frames` channels from `offset` relative to the first material frame, as silence outside
/// the readable range.
struct PaddedInput {
    const float *const *channels;
    int64_t lowest;  // -preContext
    int64_t highest; // inputFrames + postContext, exclusive
    int64_t offset;

    struct Channel {
        const float *samples;
        const PaddedInput &owner;
        float operator[](int i) const {
            const int64_t index = owner.offset + i;
            return index < owner.lowest || index >= owner.highest ? 0.f : samples[index];
        }
    };
    Channel operator[](int c) const { return {channels[c], *this}; }
};

struct OffsetOutput {
    float *const *channels;
    int64_t offset;
    float *operator[](int c) const { return channels[c] + offset; }
};

constexpr int kExactChunkFrames = 8192;

} // namespace

struct TimePitchKernel {
    Stretch stretch{kTimePitchSeed};
    uint32_t channelCount;
    double sampleRate;
    uint32_t maxOutputFrames;

    std::atomic<double> targetRate{1};
    std::atomic<double> transposeFactor{1};
    std::atomic<double> tonalityLimitHz{0};
    std::atomic<double> formantSemitones{0};
    std::atomic<bool> formantCorrection{false};
    std::atomic<double> formantBaseHz{0};
    std::atomic<uint32_t> settingsGeneration{1};
    std::atomic<bool> resetRequested{false};
    std::atomic<int64_t> sourceFramesConsumed{0};

    // Render thread only.
    uint32_t appliedGeneration = 0;
    double currentRate = 1;
    double rampTarget = 1;
    double rampStepPerFrame = 0;
    double inputDebt = 0;

    void applySettings() {
        const uint32_t generation = settingsGeneration.load(std::memory_order_acquire);
        if (generation == appliedGeneration) return;
        appliedGeneration = generation;

        const double tonality = tonalityLimitHz.load(std::memory_order_relaxed);
        const double base = formantBaseHz.load(std::memory_order_relaxed);
        stretch.setTransposeFactor(float(transposeFactor.load(std::memory_order_relaxed)), float(tonality / sampleRate));
        stretch.setFormantSemitones(float(formantSemitones.load(std::memory_order_relaxed)),
                                    formantCorrection.load(std::memory_order_relaxed));
        stretch.setFormantBase(float(base / sampleRate));
    }

    void resetState() {
        stretch.reset();
        inputDebt = 0;
        currentRate = rampTarget = targetRate.load(std::memory_order_relaxed);
        rampStepPerFrame = 0;
    }

    /// The mean rate over the next `frames` of output, advancing the ramp across them.
    double advanceRate(uint32_t frames) {
        const double target = targetRate.load(std::memory_order_relaxed);
        if (target != rampTarget) {
            rampTarget = target;
            rampStepPerFrame = (target - currentRate) / (kTimePitchRateRampSeconds * sampleRate);
        }
        if (currentRate == rampTarget) return currentRate;

        const double start = currentRate;
        const double end = currentRate + rampStepPerFrame * frames;
        const bool passes = rampStepPerFrame > 0 ? end >= rampTarget : end <= rampTarget;
        if (!passes) {
            currentRate = end;
            return (start + end) / 2;
        }
        // The ramp ends inside this block: average the ramped part with the flat remainder.
        const double rampFrames = (rampTarget - start) / rampStepPerFrame;
        currentRate = rampTarget;
        return ((start + rampTarget) / 2 * rampFrames + rampTarget * (frames - rampFrames)) / frames;
    }
};

int64_t TimePitchOutputFrameCount(int64_t inputFrames, double rate) {
    return std::llround(double(inputFrames) / rate);
}

TimePitchKernelRef TimePitchKernelCreate(uint32_t channels, double sampleRate, uint32_t maxOutputFrames,
                                         TimePitchKernelQuality quality, bool live) {
    if (channels == 0 || !(sampleRate > 0)) return nullptr;

    auto *kernel = new TimePitchKernel;
    kernel->channelCount = channels;
    kernel->sampleRate = sampleRate;
    kernel->maxOutputFrames = maxOutputFrames;

    if (quality == TimePitchKernelQualityEfficient) {
        kernel->stretch.presetCheaper(int(channels), float(sampleRate), live);
    } else {
        kernel->stretch.presetDefault(int(channels), float(sampleRate), live);
    }
    kernel->applySettings();
    return kernel;
}

void TimePitchKernelDestroy(TimePitchKernelRef kernel) { delete kernel; }

void TimePitchKernelSetTargets(TimePitchKernelRef kernel, double rate, double transposeFactor) {
    kernel->targetRate.store(std::clamp(rate, kTimePitchMinRate, kTimePitchMaxRate), std::memory_order_relaxed);
    kernel->transposeFactor.store(transposeFactor, std::memory_order_relaxed);
    kernel->settingsGeneration.fetch_add(1, std::memory_order_release);
}

void TimePitchKernelSetTimbre(TimePitchKernelRef kernel, double tonalityLimitHz, double formantSemitones,
                              bool formantCorrection, double formantBaseHz) {
    kernel->tonalityLimitHz.store(tonalityLimitHz, std::memory_order_relaxed);
    kernel->formantSemitones.store(formantSemitones, std::memory_order_relaxed);
    kernel->formantCorrection.store(formantCorrection, std::memory_order_relaxed);
    kernel->formantBaseHz.store(formantBaseHz, std::memory_order_relaxed);
    kernel->settingsGeneration.fetch_add(1, std::memory_order_release);
}

uint32_t TimePitchKernelInputFramesNeeded(TimePitchKernelRef kernel, uint32_t outputFrames) {
    if (kernel->resetRequested.exchange(false, std::memory_order_acquire)) kernel->resetState();
    kernel->applySettings();

    kernel->inputDebt += outputFrames * kernel->advanceRate(outputFrames);
    const auto frames = std::max<int64_t>(0, std::llround(kernel->inputDebt));
    kernel->inputDebt -= double(frames);
    return uint32_t(frames);
}

bool TimePitchKernelProcess(TimePitchKernelRef kernel, const float *const *input, uint32_t inputFrames,
                            float *const *output, uint32_t outputFrames) {
    if (outputFrames > kernel->maxOutputFrames) return false;
    kernel->stretch.process(input, int(inputFrames), output, int(outputFrames));
    kernel->sourceFramesConsumed.fetch_add(inputFrames, std::memory_order_relaxed);
    return true;
}

void TimePitchKernelReset(TimePitchKernelRef kernel) { kernel->resetRequested.store(true, std::memory_order_release); }

int32_t TimePitchKernelInputLatencyFrames(TimePitchKernelRef kernel) { return kernel->stretch.inputLatency(); }

int32_t TimePitchKernelOutputLatencyFrames(TimePitchKernelRef kernel) { return kernel->stretch.outputLatency(); }

double TimePitchKernelLatencySeconds(TimePitchKernelRef kernel, double rate) {
    return (kernel->stretch.outputLatency() + kernel->stretch.inputLatency() / rate) / kernel->sampleRate;
}

int64_t TimePitchKernelSourceFramesConsumed(TimePitchKernelRef kernel) {
    return kernel->sourceFramesConsumed.load(std::memory_order_relaxed);
}

namespace {

/// Where an exact render reads, relative to the first material frame.
struct ExactLayout {
    int64_t seekEnd;       // the seek's last frame, exclusive
    int64_t prerollInput;  // frames read from `seekEnd`
    int64_t prerollOutput; // output frames discarded
    int64_t materialStart; // where the kept output's input begins
};

/// After a seek ending at E, output frame j corresponds to source E − inLat − rate·outLat + j·rate.
/// So `prerollOutput` frames after the seek, output is aligned to source 0 when the preroll reads
/// `prerollOutput · rate` frames and the kept output reads from `inLat + rate·outLat`. The preroll
/// spans a whole block, so every window overlapping the first kept frame was analysed from real context.
ExactLayout exactLayout(const Stretch &stretch, double rate) {
    const int64_t inLat = stretch.inputLatency();
    const int64_t outLat = stretch.outputLatency();
    ExactLayout layout;
    layout.prerollOutput = stretch.blockSamples() + outLat;
    layout.prerollInput = std::llround(double(layout.prerollOutput) * rate);
    layout.materialStart = inLat + std::llround(rate * double(outLat));
    layout.seekEnd = layout.materialStart - layout.prerollInput;
    return layout;
}

} // namespace

void TimePitchKernelContextFrames(TimePitchKernelRef kernel, double rate, int64_t *preContext, int64_t *postContext) {
    const ExactLayout layout = exactLayout(kernel->stretch, rate);
    *preContext = std::max<int64_t>(0, kernel->stretch.seekLength() - layout.seekEnd);
    *postContext = layout.materialStart;
}

bool TimePitchKernelRenderExact(TimePitchKernelRef kernel, const float *const *input, int64_t inputFrames,
                                int64_t preContext, int64_t postContext, float *const *output, int64_t outputFrames) {
    const double targetRate = kernel->targetRate.load(std::memory_order_relaxed);
    if (inputFrames < 0 || outputFrames != TimePitchOutputFrameCount(inputFrames, targetRate)) return false;
    if (outputFrames == 0) return true;

    // The exact rate, which the rounding of the output count moves slightly off the target.
    const double rate = double(inputFrames) / double(outputFrames);
    Stretch &stretch = kernel->stretch;
    kernel->applySettings();
    stretch.reset();

    const ExactLayout layout = exactLayout(stretch, rate);
    PaddedInput source{input, -std::max<int64_t>(0, preContext), inputFrames + std::max<int64_t>(0, postContext), 0};

    const int seekLength = stretch.seekLength();
    source.offset = layout.seekEnd - seekLength;
    stretch.seek(source, seekLength, rate);

    std::vector<std::vector<float>> preroll(kernel->channelCount, std::vector<float>(layout.prerollOutput));
    source.offset = layout.seekEnd;
    stretch.process(source, int(layout.prerollInput), preroll, int(layout.prerollOutput));

    int64_t written = 0;
    int64_t read = 0;
    while (written < outputFrames) {
        const int64_t outChunk = std::min<int64_t>(kExactChunkFrames, outputFrames - written);
        const int64_t readEnd = written + outChunk == outputFrames
                                    ? inputFrames
                                    : std::llround(double(written + outChunk) * rate);
        source.offset = layout.materialStart + read;
        stretch.process(source, int(readEnd - read), OffsetOutput{output, written}, int(outChunk));
        read = readEnd;
        written += outChunk;
    }
    kernel->sourceFramesConsumed.fetch_add(layout.prerollInput + inputFrames, std::memory_order_relaxed);
    return true;
}
