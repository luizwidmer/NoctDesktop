// File-level FSEvents observer. Events have paths, not process attribution.
#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#include <signal.h>

static void changed(ConstFSEventStreamRef stream, void *info, size_t count,
                    void *eventPaths, const FSEventStreamEventFlags flags[],
                    const FSEventStreamEventId ids[]) {
    @autoreleasepool {
        char **paths = eventPaths;
        for (size_t i = 0; i < count; i++) {
            NSDictionary *event = @{ @"path": @(paths[i]), @"flags": @(flags[i]),
                                      @"id": @(ids[i]), @"time": @([[NSDate date] timeIntervalSince1970]) };
            NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
            fwrite(data.bytes, 1, data.length, stdout);
            fputc('\n', stdout);
        }
        fflush(stdout);
    }
}

static void quit(int sig) { CFRunLoopStop(CFRunLoopGetMain()); }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSMutableArray *paths = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [paths addObject:@(argv[i])];
        FSEventStreamContext context = {0, NULL, NULL, NULL, NULL};
        FSEventStreamRef stream = FSEventStreamCreate(NULL, changed, &context,
            (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow, 0.05,
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot);
        if (!stream) return 3;
        dispatch_queue_t queue = dispatch_queue_create("local.private-workspace.file-events", DISPATCH_QUEUE_SERIAL);
        FSEventStreamSetDispatchQueue(stream, queue);
        if (!FSEventStreamStart(stream)) return 4;
        fprintf(stderr, "READY\n"); fflush(stderr);
        signal(SIGTERM, quit); signal(SIGINT, quit);
        CFRunLoopRun();
        FSEventStreamFlushSync(stream);
        FSEventStreamStop(stream);
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
    }
    return 0;
}
