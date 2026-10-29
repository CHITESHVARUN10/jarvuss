#import "metadata_query.h"

BOOL JarvisStartMetadataQuery(NSMetadataQuery *query, NSPredicate *predicate,
    NSArray<NSString *> *scopes, NSArray<NSSortDescriptor *> *sortDescriptors,
    NSError **error) {
    @try {
        query.predicate = predicate;
        query.searchScopes = scopes;
        query.sortDescriptors = sortDescriptors;
        if ([query startQuery]) { return YES; }
        if (error) {
            *error = [NSError errorWithDomain:@"Jarvis.Spotlight" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Spotlight could not start this search. Check folder access and indexing."
            }];
        }
    } @catch (NSException *exception) {
        NSLog(@"[Jarvis][FileSearch] Query rejected: %@: %@", exception.name, exception.reason);
        if (error) {
            *error = [NSError errorWithDomain:@"Jarvis.Spotlight" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"Spotlight rejected this search. Try a different file type or filter.",
                @"exception": exception.name,
                @"reason": exception.reason ?: @"No exception reason supplied"
            }];
        }
    }
    return NO;
}
