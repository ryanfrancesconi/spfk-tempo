// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

#pragma once

#include "SPFKTimePitchKernel.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>


/// Planar audio.
struct Audio {
    double sampleRate = 0;
    std::vector<std::vector<float>> channels;

    int channelCount() const { return int(channels.size()); }
    int64_t frames() const { return channels.empty() ? 0 : int64_t(channels[0].size()); }

    static Audio silence(int channelCount, int64_t frames, double sampleRate) {
        Audio a;
        a.sampleRate = sampleRate;
        a.channels.assign(channelCount, std::vector<float>(size_t(frames), 0.f));
        return a;
    }

    std::vector<const float *> readPointers(int64_t offset = 0) const {
        std::vector<const float *> p;
        for (auto &c : channels) p.push_back(c.data() + offset);
        return p;
    }
    std::vector<float *> writePointers(int64_t offset = 0) {
        std::vector<float *> p;
        for (auto &c : channels) p.push_back(c.data() + offset);
        return p;
    }
};

/// Reads PCM 16/24/32-bit integer or 32-bit float WAV, including WAVE_FORMAT_EXTENSIBLE.
inline bool readWav(const std::string &path, Audio &out) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) return false;
    std::vector<uint8_t> bytes;
    uint8_t chunk[65536];
    size_t n;
    while ((n = std::fread(chunk, 1, sizeof chunk, f)) > 0) bytes.insert(bytes.end(), chunk, chunk + n);
    std::fclose(f);
    if (bytes.size() < 12 || std::memcmp(bytes.data(), "RIFF", 4) || std::memcmp(bytes.data() + 8, "WAVE", 4)) return false;

    auto u16 = [&](size_t o) { return uint16_t(bytes[o] | bytes[o + 1] << 8); };
    auto u32 = [&](size_t o) { return uint32_t(u16(o) | uint32_t(u16(o + 2)) << 16); };
    int format = 0, channels = 0, bits = 0;
    double rate = 0;
    size_t pos = 12;
    while (pos + 8 <= bytes.size()) {
        const uint32_t size = u32(pos + 4);
        const size_t body = pos + 8;
        if (!std::memcmp(bytes.data() + pos, "fmt ", 4)) {
            format = u16(body);
            channels = u16(body + 2);
            rate = u32(body + 4);
            bits = u16(body + 14);
            if (format == 0xFFFE) format = u16(body + 24);
        } else if (!std::memcmp(bytes.data() + pos, "data", 4)) {
            if (channels == 0) return false;
            const int bytesPer = bits / 8;
            const size_t available = std::min<size_t>(size, bytes.size() - body);
            const int64_t frames = int64_t(available / size_t(bytesPer * channels));
            out = Audio::silence(channels, frames, rate);
            for (int64_t i = 0; i < frames; ++i) {
                for (int c = 0; c < channels; ++c) {
                    const uint8_t *s = bytes.data() + body + size_t((i * channels + c) * bytesPer);
                    float v = 0;
                    if (format == 3 && bits == 32) {
                        std::memcpy(&v, s, 4);
                    } else if (format == 1 && bits == 16) {
                        v = int16_t(s[0] | s[1] << 8) / 32768.f;
                    } else if (format == 1 && bits == 24) {
                        int32_t x = s[0] | s[1] << 8 | s[2] << 16;
                        if (x & 0x800000) x |= ~0xFFFFFF;
                        v = x / 8388608.f;
                    } else if (format == 1 && bits == 32) {
                        int32_t x;
                        std::memcpy(&x, s, 4);
                        v = float(x / 2147483648.0);
                    } else {
                        return false;
                    }
                    out.channels[c][size_t(i)] = v;
                }
            }
            return true;
        }
        pos = body + size + (size & 1);
    }
    return false;
}

/// Writes 32-bit float WAV, for listening.
inline bool writeWav(const std::string &path, const Audio &a) {
    FILE *f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const uint32_t ch = uint32_t(a.channelCount()), sr = uint32_t(a.sampleRate);
    const uint32_t dataBytes = uint32_t(a.frames()) * ch * 4;
    auto put32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto put16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f);
    put32(36 + dataBytes);
    std::fwrite("WAVEfmt ", 1, 8, f);
    put32(16), put16(3), put16(uint16_t(ch)), put32(sr), put32(sr * ch * 4), put16(uint16_t(ch * 4)), put16(32);
    std::fwrite("data", 1, 4, f);
    put32(dataBytes);
    for (int64_t i = 0; i < a.frames(); ++i)
        for (auto &c : a.channels) std::fwrite(&c[size_t(i)], 4, 1, f);
    std::fclose(f);
    return true;
}

inline Audio noise(int channelCount, int64_t frames, double sampleRate, uint32_t seed = 1) {
    Audio a = Audio::silence(channelCount, frames, sampleRate);
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> d(-0.5f, 0.5f);
    for (auto &c : a.channels)
        for (auto &v : c) v = d(rng);
    return a;
}

inline double rms(const std::vector<float> &x, int64_t from = 0, int64_t to = -1) {
    if (to < 0) to = int64_t(x.size());
    double s = 0;
    for (int64_t i = from; i < to; ++i) s += double(x[size_t(i)]) * x[size_t(i)];
    return to > from ? std::sqrt(s / double(to - from)) : 0;
}

inline double dB(double ratio) { return 20 * std::log10(std::max(ratio, 1e-12)); }

/// The level of `a − b` relative to `b` over `[from, to)`, across every channel.
inline double nullDB(const Audio &a, const Audio &b, int64_t from, int64_t to, int64_t lagOfA = 0) {
    double diff = 0, ref = 0;
    for (int c = 0; c < b.channelCount(); ++c)
        for (int64_t i = from; i < to; ++i) {
            const double x = a.channels[c][size_t(i + lagOfA)], y = b.channels[c][size_t(i)];
            diff += (x - y) * (x - y);
            ref += y * y;
        }
    return dB(std::sqrt(diff / std::max(ref, 1e-30)));
}

/// Index of the largest |sample|, summed over channels, within `[from, to)`.
inline int64_t peakIndex(const Audio &a, int64_t from, int64_t to) {
    from = std::max<int64_t>(0, from), to = std::min(to, a.frames());
    int64_t best = from;
    double bestValue = -1;
    for (int64_t i = from; i < to; ++i) {
        double v = 0;
        for (auto &c : a.channels) v += std::fabs(c[size_t(i)]);
        if (v > bestValue) bestValue = v, best = i;
    }
    return best;
}

struct Kernel {
    TimePitchKernelRef ref;
    Kernel(int ch, double sr, uint32_t maxFrames, TimePitchKernelQuality q, bool live)
        : ref(TimePitchKernelCreate(uint32_t(ch), sr, maxFrames, q, live)) {}
    ~Kernel() { TimePitchKernelDestroy(ref); }
    Kernel(const Kernel &) = delete;
    Kernel &operator=(const Kernel &) = delete;
};

/// An offline render of `material` frames starting at `start`, using every frame of `source` around it as context.
inline bool renderExact(TimePitchKernelRef k, const Audio &source, int64_t start, int64_t material, double rate,
                        Audio &out) {
    out = Audio::silence(source.channelCount(), TimePitchOutputFrameCount(material, rate), source.sampleRate);
    const auto in = source.readPointers(start);
    auto o = out.writePointers();
    return TimePitchKernelRenderExact(k, in.data(), material, start, source.frames() - start - material, o.data(),
                                      out.frames());
}

/// Streams `source` through a live kernel in `block`-frame output blocks for `outputFrames`, reading
/// silence past its end, as the AU will.
inline Audio renderLive(TimePitchKernelRef k, const Audio &source, int64_t outputFrames, uint32_t block) {
    const int ch = source.channelCount();
    Audio out = Audio::silence(ch, outputFrames, source.sampleRate);
    Audio in = Audio::silence(ch, int64_t(block * kTimePitchMaxRate) + 2, source.sampleRate);
    int64_t read = 0;
    for (int64_t written = 0; written < outputFrames; written += block) {
        const uint32_t n = uint32_t(std::min<int64_t>(block, outputFrames - written));
        const uint32_t need = TimePitchKernelInputFramesNeeded(k, n);
        for (int c = 0; c < ch; ++c)
            for (uint32_t i = 0; i < need; ++i)
                in.channels[c][i] = read + i < source.frames() ? source.channels[c][size_t(read + i)] : 0.f;
        read += need;
        const auto ip = in.readPointers();
        auto op = out.writePointers(written);
        TimePitchKernelProcess(k, ip.data(), need, op.data(), n);
    }
    return out;
}

// MARK: - Allocation counting

/// Counts every malloc-family call from any image while `counting` is set, through dyld interposing.
namespace alloc {
inline std::atomic<bool> counting{false};
inline std::atomic<long> count{0};
inline void note() {
    if (counting.load(std::memory_order_relaxed)) count.fetch_add(1, std::memory_order_relaxed);
}
} // namespace alloc
