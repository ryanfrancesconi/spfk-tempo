// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BPMDetectC : NSObject

- (id)initWithSampleRate:(int)sampleRate numberOfChannels:(int)numberOfChannels;

- (void)process:(const float *)data numberOfSamples:(int)numberOfSamples;

- (float)getBpm;

@end

NS_ASSUME_NONNULL_END
