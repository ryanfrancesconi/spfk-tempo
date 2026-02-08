// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-tempo

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// objc++ wrapper on soundtouch BPMDetect for Swift access
@interface BPMDetectC : NSObject

- (instancetype)init;

- (instancetype)initWithSampleRate:(int)sampleRate
                  numberOfChannels:(int)numberOfChannels
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithFormat:(AVAudioFormat *)format;

/// Inputs a block of samples for analyzing: Envelopes the samples and then
/// updates the autocorrelation estimation.
- (void)process:(const float *)data numberOfSamples:(int)numberOfSamples;

/// Can be called at any time once the underlying class has enough samples.
- (float)getBpm;

@end

NS_ASSUME_NONNULL_END
