// Copyright Ryan Francesconi. All Rights Reserved. Revision History at
// https://github.com/ryanfrancesconi/spfk-tempo

#import <iostream>

#import "BPMDetect.h"
#import "STTypes.h"

#import "DetectTempo.h"

@implementation DetectTempo {
    soundtouch::BPMDetect *_bpmDetect;
}

- (instancetype)init {
    return [self initWithSampleRate:44100 numberOfChannels:2]; // dummy init
}

- (instancetype)initWithSampleRate:(int)sampleRate
                  numberOfChannels:(int)numberOfChannels {
    self = [super init];

    if (self) {
        _bpmDetect = new soundtouch::BPMDetect(numberOfChannels, sampleRate);
    }

    return self;
}

- (instancetype)initWithFormat:(AVAudioFormat *)format {
    return [self initWithSampleRate:(int)format.sampleRate
                   numberOfChannels:(int)format.channelCount];
}

- (void)process:(const float *)data numberOfSamples:(int)numberOfSamples {
    _bpmDetect->inputSamples(data, numberOfSamples);
}

- (float)getBpm {
    return _bpmDetect->getBpm();
}

- (int)getBeats {
    return _bpmDetect->getBeats(nil, nil, 100);
}

- (void)dealloc {
    if (_bpmDetect) {
        delete _bpmDetect;
        _bpmDetect = nullptr;
    }
}

@end
