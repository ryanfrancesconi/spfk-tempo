// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo
//
// usage: spfk-time-pitch-bench <stereo fixture.wav> [listening output dir]
// Build with `swift build -c release`; Debug numbers are meaningless.

#include "Support.hpp"

#include <chrono>
#include <new>

#include <Accelerate/Accelerate.h>

// libmalloc's own logging hook, which MallocStackLogging installs; it is called for every
// allocation from every image. Type bit 2 is an allocation (`MALLOC_LOG_TYPE_ALLOCATE`).
typedef void(MallocLogger)(uint32_t type, uintptr_t, uintptr_t, uintptr_t, uintptr_t result, uint32_t);
extern "C" MallocLogger *malloc_logger;
static void countingLogger(uint32_t type, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t) {
    if (type & 2) alloc::note();
}

// A second, independent count: every C++ allocation, whichever zone serves it.
std::atomic<long> newCount{0};
void *operator new(size_t size) {
    if (alloc::counting.load(std::memory_order_relaxed)) newCount.fetch_add(1, std::memory_order_relaxed);
    if (void *p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, size_t) noexcept { std::free(p); }

namespace {

const double kSampleRates[] = {44100, 48000, 96000, 192000};
const double kRates[] = {0.5, 0.8, 0.97, 1, 1.03, 1.25, 1.5, 2};
int failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        ++failures;
        std::printf("  FAIL: %s\n", what);
    }
}

// MARK: - (a) exactness

void measureExactness() {
    std::printf("\n(a) Exactness: out == round(in / rate)\n");
    // Under one block (the shortest block is 4410 frames at 44.1 kHz), primes, and a long file.
    const int64_t lengths[] = {1, 2, 7, 100, 509, 4093, 48017, 210899};
    int cases = 0, exact = 0, silent = 0;
    for (double sr : kSampleRates) {
        Kernel k(2, sr, 0, TimePitchKernelQualityBest, false);
        for (double rate : kRates) {
            TimePitchKernelSetTargets(k.ref, rate, 1);
            for (int64_t n : lengths) {
                const Audio src = noise(2, n, sr, uint32_t(n));
                Audio out;
                const bool ok = renderExact(k.ref, src, 0, n, rate, out);
                ++cases;
                if (ok && out.frames() == std::llround(double(n) / rate)) ++exact;
                // Content reaches the last tenth of a file long enough to judge.
                if (n >= 48000 && rms(out.channels[0], out.frames() * 9 / 10) < 0.05) ++silent;
            }
            // A wrong count is refused.
            Audio src = noise(2, 1000, sr), wrong = Audio::silence(2, TimePitchOutputFrameCount(1000, rate) + 1, sr);
            const auto ip = src.readPointers();
            auto op = wrong.writePointers();
            check(!TimePitchKernelRenderExact(k.ref, ip.data(), 1000, 0, 0, op.data(), wrong.frames()),
                  "a wrong output count is refused");
        }
    }
    std::printf("  %d/%d renders exact; %d with a silent last tenth\n", exact, cases, silent);
    check(exact == cases && silent == 0, "every render exact and filled");

    // The live accumulator: random block sizes, total input == round(total output × rate).
    int liveCases = 0, liveExact = 0;
    std::mt19937 rng(7);
    for (double rate : kRates) {
        Kernel k(1, 48000, 4096, TimePitchKernelQualityBest, true);
        TimePitchKernelSetTargets(k.ref, rate, 1);
        TimePitchKernelReset(k.ref);
        int64_t totalOut = 0, totalIn = 0;
        for (int b = 0; b < 2000; ++b) {
            const uint32_t n = 1 + rng() % 1024;
            totalIn += TimePitchKernelInputFramesNeeded(k.ref, n);
            totalOut += n;
        }
        ++liveCases;
        if (totalIn == std::llround(double(totalOut) * rate)) ++liveExact;
    }
    std::printf("  live accumulator: %d/%d runs consume round(output × rate)\n", liveExact, liveCases);
    check(liveExact == liveCases, "live accumulator exact");
}

// MARK: - (b) alignment

Audio clickTrack(double sr, double seconds, double first, double spacing, std::vector<double> &times) {
    Audio a = Audio::silence(2, int64_t(seconds * sr), sr);
    for (double t = first; t < seconds - 0.05; t += spacing) {
        times.push_back(t);
        const int64_t at = std::llround(t * sr);
        a.channels[0][size_t(at)] = a.channels[1][size_t(at)] = 0.9f;
    }
    return a;
}

void measureAlignment() {
    std::printf("\n(b) Alignment: click onsets at round(t / rate), searched within ±2 intervals\n");
    std::printf("  %-8s %-6s %-14s %-14s %s\n", "sr", "rate", "whole max|Δ|", "window max|Δ|", "interval");
    for (double sr : {48000.0, 192000.0}) {
        for (double rate : kRates) {
            Kernel k(2, sr, 0, TimePitchKernelQualityBest, false);
            TimePitchKernelSetTargets(k.ref, rate, 1);
            const int64_t interval = std::llround(sr * 0.03);
            std::vector<double> times;
            const Audio src = clickTrack(sr, 4, 0.13, 0.25, times);

            auto worst = [&](const Audio &out, double offsetSeconds, double from, double to) {
                int64_t w = 0;
                for (double t : times) {
                    if (t < from || t >= to) continue;
                    const int64_t expected = std::llround((t - offsetSeconds) * sr / rate);
                    const int64_t found = peakIndex(out, expected - 2 * interval, expected + 2 * interval + 1);
                    w = std::max(w, std::llabs(found - expected));
                }
                return w;
            };
            Audio whole, window;
            renderExact(k.ref, src, 0, src.frames(), rate, whole);
            // A trimmed window from 1.0 s to 3.0 s, with the rest of the file as context.
            const int64_t start = int64_t(sr), length = int64_t(2 * sr);
            renderExact(k.ref, src, start, length, rate, window);
            const int64_t a = worst(whole, 0, 0, 4), b = worst(window, 1.0, 1.0, 3.0);
            std::printf("  %-8.0f %-6.2f %-14lld %-14lld %lld\n", sr, rate, a, b, interval);
            check(a <= interval && b <= interval, "onsets within one interval");
        }
    }
}

// MARK: - (c) identity

void measureIdentity(const Audio &fixture) {
    std::printf("\n(c) Identity at rate 1 / pitch 0\n");
    const double sr = fixture.sampleRate;
    Kernel k(fixture.channelCount(), sr, 512, TimePitchKernelQualityBest, false);
    Audio whole, window;
    renderExact(k.ref, fixture, 0, fixture.frames(), 1, whole);
    std::printf("  exact, whole file:             %.1f dB\n", nullDB(whole, fixture, 0, fixture.frames()));
    const int64_t start = int64_t(sr), length = int64_t(2 * sr);
    renderExact(k.ref, fixture, start, length, 1, window);
    Audio windowSource = Audio::silence(fixture.channelCount(), length, sr);
    for (int c = 0; c < fixture.channelCount(); ++c)
        std::copy_n(fixture.channels[c].begin() + start, length, windowSource.channels[c].begin());
    std::printf("  exact, 1–3 s window w/ context: %.1f dB\n", nullDB(window, windowSource, 0, length));

    for (bool split : {false, true}) {
        Kernel live(fixture.channelCount(), sr, 512, TimePitchKernelQualityBest, split);
        const int64_t lag = std::llround(TimePitchKernelLatencySeconds(live.ref, 1) * sr);
        const Audio out = renderLive(live.ref, fixture, fixture.frames() + lag, 512);
        std::printf("  live 512-frame blocks, split %-3s: %.1f dB after %lld frames latency\n", split ? "on" : "off",
                    nullDB(out, fixture, 0, fixture.frames(), lag), lag);
    }
}

// MARK: - (d) latency

void measureLatency() {
    std::printf("\n(d) Latency against an impulse, live 512-frame blocks\n");
    std::printf("  %-8s %-6s %-5s %-8s %-8s %-12s %-12s %s\n", "sr", "split", "rate", "inLat", "outLat", "predicted",
                "measured", "L(r) ms");
    for (double sr : kSampleRates)
        for (bool split : {false, true})
            for (double rate : {0.5, 1.0, 2.0}) {
                Kernel k(1, sr, 512, TimePitchKernelQualityBest, split);
                TimePitchKernelSetTargets(k.ref, rate, 1);
                TimePitchKernelReset(k.ref);
                const int64_t at = int64_t(sr / 2);
                Audio src = Audio::silence(1, int64_t(sr * 2), sr);
                src.channels[0][size_t(at)] = 1;
                const double L = TimePitchKernelLatencySeconds(k.ref, rate);
                const int64_t predicted = std::llround(double(at) / rate + L * sr);
                const Audio out = renderLive(k.ref, src, int64_t(sr * 2 / rate), 512);
                const int64_t measured = peakIndex(out, 0, out.frames());
                std::printf("  %-8.0f %-6s %-5.1f %-8d %-8d %-12lld %-12lld %.2f\n", sr, split ? "on" : "off", rate,
                            TimePitchKernelInputLatencyFrames(k.ref), TimePitchKernelOutputLatencyFrames(k.ref),
                            predicted, measured, L * 1000);
                check(std::llabs(measured - predicted) <= 2, "impulse heard at L(r)");
            }
}

// MARK: - (e) CPU and allocations

void measureCPU() {
    std::printf("\n(e) CPU, live 512-frame blocks (split on), 20 s of noise; realtime multiple = audio / CPU time\n");
    std::printf("  %-8s %-3s %-10s %-5s %-10s %-14s %s\n", "sr", "ch", "quality", "rate", "realtime×",
                "worst block", "block budget");
    for (double sr : {48000.0, 192000.0})
        for (int ch : {1, 2, 6})
            for (auto q : {TimePitchKernelQualityBest, TimePitchKernelQualityEfficient})
                for (double rate : {0.5, 1.0, 2.0}) {
                    Kernel k(ch, sr, 512, q, true);
                    TimePitchKernelSetTargets(k.ref, rate, 1);
                    TimePitchKernelReset(k.ref);
                    const Audio src = noise(ch, int64_t(sr * 20 * kTimePitchMaxRate) + 1024, sr);
                    Audio out = Audio::silence(ch, 512, sr);
                    const int64_t blocks = int64_t(sr * 20 / 512);
                    int64_t read = 0;
                    double total = 0, worst = 0;
                    for (int64_t b = 0; b < blocks; ++b) {
                        const uint32_t need = TimePitchKernelInputFramesNeeded(k.ref, 512);
                        const auto ip = src.readPointers(read);
                        auto op = out.writePointers();
                        const auto t0 = std::chrono::steady_clock::now();
                        TimePitchKernelProcess(k.ref, ip.data(), need, op.data(), 512);
                        const double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                        total += dt, worst = std::max(worst, dt);
                        read += need;
                    }
                    std::printf("  %-8.0f %-3d %-10s %-5.1f %-10.1f %-14.3f %.3f ms\n", sr, ch,
                                q == TimePitchKernelQualityBest ? "best" : "efficient", rate,
                                double(blocks) * 512 / sr / total, worst * 1000, 512 / sr * 1000);
                }

    std::printf("  offline exact render, stereo 48 kHz, 20 s:\n");
    for (auto q : {TimePitchKernelQualityBest, TimePitchKernelQualityEfficient})
        for (double rate : {0.5, 1.0, 2.0}) {
            Kernel k(2, 48000, 0, q, false);
            TimePitchKernelSetTargets(k.ref, rate, 1);
            const Audio src = noise(2, 48000 * 20, 48000);
            Audio out;
            const auto t0 = std::chrono::steady_clock::now();
            renderExact(k.ref, src, 0, src.frames(), rate, out);
            const double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            std::printf("    %-10s rate %.1f: %.1f× realtime (of output)\n",
                        q == TimePitchKernelQualityBest ? "best" : "efficient", rate, double(out.frames()) / 48000 / dt);
        }
}

void measureAllocations() {
    std::printf("\n(e) Allocations after create, live render with every setter swept mid-render\n");
    malloc_logger = countingLogger;
    alloc::counting = true;
    {
        auto *volatile probe = new std::vector<float>(1000);
        delete probe;
        char *volatile copy = strdup("probe");
        std::free(copy);
        FFTSetup setup = vDSP_create_fftsetup(12, kFFTRadix2);
        vDSP_destroy_fftsetup(setup);
    }
    alloc::counting = false;
    const long probe = alloc::count.exchange(0), probeNew = newCount.exchange(0);
    std::printf("  hook self-test: malloc %ld, operator new %ld (expected ≥ 2 and ≥ 1)\n", probe, probeNew);
    check(probe >= 2 && probeNew >= 1, "the hooks see allocations");

    for (double sr : {48000.0, 192000.0})
        for (int ch : {1, 2, 6})
            for (auto q : {TimePitchKernelQualityBest, TimePitchKernelQualityEfficient}) {
                Kernel k(ch, sr, 512, q, true);
                const Audio src = noise(ch, 4096, sr);
                Audio out = Audio::silence(ch, 512, sr);
                const auto ip = src.readPointers();
                auto op = out.writePointers();
                alloc::count = 0;
                newCount = 0;
                alloc::counting = true;
                for (int b = 0; b < 4000; ++b) {
                    switch (b % 400) {
                    case 50: TimePitchKernelSetTargets(k.ref, 0.5 + (b % 7) * 0.25, std::pow(2, (b % 5 - 2) / 12.0)); break;
                    case 100: TimePitchKernelSetTimbre(k.ref, 8000, 0, true, 0); break;
                    case 150: TimePitchKernelSetTimbre(k.ref, 4000, 3, true, 200); break;
                    case 200: TimePitchKernelSetTimbre(k.ref, 0, -4, false, 0); break;
                    case 250: TimePitchKernelReset(k.ref); break;
                    case 300: TimePitchKernelSetTargets(k.ref, 2, 0.5); break;
                    case 350: TimePitchKernelSetTimbre(k.ref, 0, 0, false, 0); break;
                    }
                    const uint32_t need = TimePitchKernelInputFramesNeeded(k.ref, 512);
                    TimePitchKernelProcess(k.ref, ip.data(), need, op.data(), 512);
                }
                alloc::counting = false;
                std::printf("  %-6.0f %d ch %-9s: %ld malloc / %ld operator-new allocations in 4000 blocks\n", sr, ch,
                            q == TimePitchKernelQualityBest ? "best" : "efficient", alloc::count.load(), newCount.load());
                check(alloc::count == 0 && newCount == 0, "no allocation after create");
            }
}

// MARK: - (e2) determinism

void measureDeterminism(const Audio &fixture) {
    std::printf("\n(e2) Determinism: two renders with the fixed seed\n");
    for (double rate : {0.5, 1.5}) {
        Audio a, b, c;
        {
            Kernel k(fixture.channelCount(), fixture.sampleRate, 0, TimePitchKernelQualityBest, false);
            TimePitchKernelSetTargets(k.ref, rate, std::pow(2, 3 / 12.0));
            renderExact(k.ref, fixture, 0, fixture.frames(), rate, a);
            renderExact(k.ref, fixture, 0, fixture.frames(), rate, c);
        }
        Kernel k(fixture.channelCount(), fixture.sampleRate, 0, TimePitchKernelQualityBest, false);
        TimePitchKernelSetTargets(k.ref, rate, std::pow(2, 3 / 12.0));
        renderExact(k.ref, fixture, 0, fixture.frames(), rate, b);
        const bool fresh = a.channels == b.channels, reused = a.channels == c.channels;
        std::printf("  rate %.1f, +3 st: fresh kernels %s, same kernel twice %s\n", rate,
                    fresh ? "bit-identical" : "DIFFER", reused ? "bit-identical" : "DIFFER");
        check(fresh && reused, "bit-identical renders");
    }
}

// MARK: - (f) stereo coherence

struct Coherence {
    double monoSumDB, correlation;
};
Coherence coherence(const Audio &a) {
    double ll = 0, rr = 0, lr = 0, sum = 0;
    for (int64_t i = 0; i < a.frames(); ++i) {
        const double l = a.channels[0][size_t(i)], r = a.channels[1][size_t(i)];
        ll += l * l, rr += r * r, lr += l * r, sum += (l + r) * (l + r) / 4;
    }
    return {dB(std::sqrt(sum / ((ll + rr) / 2))), lr / std::sqrt(ll * rr)};
}

void measureCoherence(const Audio &fixture) {
    std::printf("\n(f) Stereo coherence: mono-sum level relative to the channel mean, and L/R correlation\n");
    const Coherence s = coherence(fixture);
    std::printf("  source                 mono sum %+.2f dB, correlation %.4f\n", s.monoSumDB, s.correlation);
    struct Case {
        const char *name;
        double rate, semitones;
    } cases[] = {{"0.5×", 0.5, 0}, {"0.75×", 0.75, 0}, {"1.5×", 1.5, 0}, {"2×", 2, 0}, {"+3 st", 1, 3},
                 {"+12 st", 1, 12}, {"0.8× +2 st", 0.8, 2}};
    for (auto &cs : cases) {
        Kernel k(2, fixture.sampleRate, 0, TimePitchKernelQualityBest, false);
        TimePitchKernelSetTargets(k.ref, cs.rate, std::pow(2, cs.semitones / 12));
        Audio out;
        renderExact(k.ref, fixture, 0, fixture.frames(), cs.rate, out);
        const Coherence c = coherence(out);
        std::printf("  %-22s mono sum %+.2f dB, correlation %.4f\n", cs.name, c.monoSumDB, c.correlation);
    }

    // Identical channels must stay identical.
    Audio dual = fixture;
    dual.channels[1] = dual.channels[0];
    Kernel k(2, fixture.sampleRate, 0, TimePitchKernelQualityBest, false);
    TimePitchKernelSetTargets(k.ref, 0.75, std::pow(2, 3 / 12.0));
    Audio out;
    renderExact(k.ref, dual, 0, dual.frames(), 0.75, out);
    float worst = 0;
    for (int64_t i = 0; i < out.frames(); ++i)
        worst = std::max(worst, std::fabs(out.channels[0][size_t(i)] - out.channels[1][size_t(i)]));
    std::printf("  L = R source at 0.75× +3 st: max |L − R| = %g\n", worst);
}

// MARK: - (f2) timbre options without a pitch shift, (f3) formant shift

Audio renderWith(const Audio &src, double rate, double semitones, double tonality, double formantSt, bool correction,
                 double base) {
    Kernel k(src.channelCount(), src.sampleRate, 0, TimePitchKernelQualityBest, false);
    TimePitchKernelSetTargets(k.ref, rate, std::pow(2, semitones / 12));
    TimePitchKernelSetTimbre(k.ref, tonality, formantSt, correction, base);
    Audio out;
    renderExact(k.ref, src, 0, src.frames(), rate, out);
    return out;
}

double rmsDB(const Audio &a) {
    double s = 0;
    for (auto &c : a.channels) s += rms(c) * rms(c);
    return dB(std::sqrt(s / a.channelCount()));
}

void measureTimbre(const Audio &fixture, const std::string &listenDir) {
    std::printf("\n(f2) Timbre options at 1.5× with zero pitch, against the same render with both off\n");
    const Audio base = renderWith(fixture, 1.5, 0, 0, 0, false, 0);
    struct Case {
        const char *name;
        double tonality;
        bool correction;
        double formantBase;
    } cases[] = {{"formant correction", 0, true, 0},
                 {"tonality limit 8 kHz", 8000, false, 0},
                 {"both", 8000, true, 0},
                 {"correction, base 200 Hz", 0, true, 200}};
    std::printf("  baseline RMS %.2f dB\n", rmsDB(base));
    for (auto &cs : cases) {
        const Audio out = renderWith(fixture, 1.5, 0, cs.tonality, 0, cs.correction, cs.formantBase);
        std::printf("  %-26s null %.1f dB, RMS change %+.3f dB\n", cs.name, nullDB(out, base, 0, base.frames()),
                    rmsDB(out) - rmsDB(base));
    }

    std::printf("\n(f3) Formant shift at identity rate and pitch\n");
    for (double st : {4.0, -4.0}) {
        const Audio out = renderWith(fixture, 1, 0, 0, st, false, 0);
        std::printf("  %+.0f st: %lld frames (source %lld), null vs source %.1f dB, RMS change %+.2f dB\n", st,
                    out.frames(), fixture.frames(), nullDB(out, fixture, 0, fixture.frames()),
                    rmsDB(out) - rmsDB(fixture));
        check(out.frames() == fixture.frames(), "formant shift keeps the length");
        if (!listenDir.empty()) {
            char name[64];
            std::snprintf(name, sizeof name, "/F%+.0f_formant_shift.wav", st);
            writeWav(listenDir + name, out);
        }
    }
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <stereo fixture.wav> [listening output dir]\n", argv[0]);
        return 2;
    }
    Audio fixture;
    if (!readWav(argv[1], fixture) || fixture.channelCount() != 2) {
        std::fprintf(stderr, "could not read a stereo WAV from %s\n", argv[1]);
        return 2;
    }
    std::printf("fixture: %s, %.0f Hz, %d ch, %lld frames\n", argv[1], fixture.sampleRate, fixture.channelCount(),
                fixture.frames());
    const std::string listenDir = argc > 2 ? argv[2] : "";

    measureExactness();
    measureAlignment();
    measureIdentity(fixture);
    measureLatency();
    measureDeterminism(fixture);
    measureCoherence(fixture);
    measureTimbre(fixture, listenDir);
    measureCPU();
    measureAllocations();

    std::printf("\n%s: %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
