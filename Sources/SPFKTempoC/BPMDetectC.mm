// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-tempo

#import <iostream>

#import "BPMDetect.h"
#import "BPMDetectC.h"
#import "STTypes.h"

/// objc++ wrapper on soundtouch BPMDetect for swift
@implementation BPMDetectC {
    soundtouch::BPMDetect *_bpmDetect;
}

- (id)initWithSampleRate:(int)sampleRate
        numberOfChannels:(int)numberOfChannels {
    self = [super init];

    if (self) {
        _bpmDetect = new soundtouch::BPMDetect(numberOfChannels, sampleRate);
    }

    return self;
}

- (void)process:(const float *)data numberOfSamples:(int)numberOfSamples {
    _bpmDetect->inputSamples(data, numberOfSamples);
}

- (float)getBpm {
    return _bpmDetect->getBpm();
}

- (void)dealloc {
    if (_bpmDetect) {
        delete _bpmDetect;
        _bpmDetect = nullptr;
    }
}

@end
