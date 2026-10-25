#import <Foundation/Foundation.h>
#import "audio_exception.h"

CFStringRef JarvisCatchAudioException(void (^operation)(void)) {
    @try {
        operation();
        return NULL;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return CFStringCreateCopy(kCFAllocatorDefault, (__bridge CFStringRef)reason);
    }
}
