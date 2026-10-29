#pragma once
#import <Foundation/Foundation.h>

// Catch exceptions entirely in Objective-C; never unwind them through Swift.
BOOL JarvisStartMetadataQuery(NSMetadataQuery * _Nonnull query,
    NSPredicate * _Nonnull predicate, NSArray<NSString *> * _Nonnull scopes,
    NSArray<NSSortDescriptor *> * _Nonnull sortDescriptors,
    NSError * _Nullable * _Nullable error) __attribute__((swift_error(none)));
