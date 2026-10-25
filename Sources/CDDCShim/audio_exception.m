#import <Foundation/Foundation.h>
#include <math.h>
#import "audio_exception.h"

void JarvisStopAudioEngine(AVAudioEngine *engine, bool removeTap) {
    @try { [engine stop]; }
    @catch (NSException *exception) { NSLog(@"[Jarvis][Mic] Stop: %@", exception.reason); }
    if (removeTap) {
        @try { [engine.inputNode removeTapOnBus:0]; }
        @catch (NSException *exception) { NSLog(@"[Jarvis][Mic] Remove tap: %@", exception.reason); }
    }
}

CFStringRef JarvisStartAudioEngine(AVAudioEngine *engine, AVAudioNodeTapBlock tap) {
    BOOL installed = NO;
    NSString *failure = nil;
    @try {
        AVAudioInputNode *input = engine.inputNode;
        AVAudioFormat *format = [input outputFormatForBus:0];
        if (!isfinite(format.sampleRate) || format.sampleRate <= 0 || format.channelCount == 0) {
            failure = @"No microphone input is ready";
        } else {
            [input installTapOnBus:0 bufferSize:2048 format:format block:tap];
            installed = YES;
            [engine prepare];
            NSError *error = nil;
            if (![engine startAndReturnError:&error]) {
                failure = error.localizedDescription ?: @"Audio engine could not start";
            }
        }
    } @catch (NSException *exception) {
        failure = exception.reason ?: exception.name;
    }
    if (failure) {
        CFStringRef result = CFStringCreateCopy(kCFAllocatorDefault, (__bridge CFStringRef)failure);
        JarvisStopAudioEngine(engine, installed);
        return result;
    }
    return NULL;
}
