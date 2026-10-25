#pragma once
#import <AVFAudio/AVFAudio.h>
#include <CoreFoundation/CoreFoundation.h>

// All potentially throwing Objective-C calls stay inside this implementation.
// Never execute a Swift operation inside an Objective-C exception catcher.
CFStringRef _Nullable JarvisStartAudioEngine(AVAudioEngine * _Nonnull engine,
    AVAudioNodeTapBlock _Nonnull tap) CF_RETURNS_RETAINED;
void JarvisStopAudioEngine(AVAudioEngine * _Nonnull engine, bool removeTap);
