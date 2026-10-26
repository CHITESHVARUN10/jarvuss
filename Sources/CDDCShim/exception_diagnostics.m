#import <Foundation/Foundation.h>
#include <stdio.h>
#include "exception_diagnostics.h"

static NSUncaughtExceptionHandler *previousHandler;
static void logUncaughtException(NSException *exception) {
    @try {
        NSString *entry = [NSString stringWithFormat:@"\n[Jarvis][UncaughtException] %@: %@\n%@\n",
            exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]];
        fputs(entry.UTF8String, stderr);
        fflush(stderr);
    } @catch (NSException *loggingError) {
        fputs("[Jarvis][UncaughtException] Could not format exception details\n", stderr);
    }
    if (previousHandler) previousHandler(exception);
}
void JarvisInstallExceptionLogging(void) {
    NSUncaughtExceptionHandler *handler = NSGetUncaughtExceptionHandler();
    if (handler != logUncaughtException) {
        previousHandler = handler;
        NSSetUncaughtExceptionHandler(logUncaughtException);
    }
}
