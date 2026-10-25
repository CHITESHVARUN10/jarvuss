#pragma once
#include <CoreFoundation/CoreFoundation.h>

// Swift do/catch cannot intercept AVAudioEngine's Objective-C exceptions.
// Translate device-change races into a recoverable diagnostic.
CFStringRef _Nullable JarvisCatchAudioException(void (^ _Nonnull operation)(void)) CF_RETURNS_RETAINED;
