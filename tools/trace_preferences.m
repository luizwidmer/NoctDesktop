// Research instrumentation for our unmodified Chromium development snapshot.
// Records call names and keys, never values. It changes no preference behavior.
// It is opt-in, copied inside the vault, and never used for normal launches.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <execinfo.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

static FILE *output;
static unsigned traces;
static void record(const char *call, CFStringRef key) {
    if (!output) return;
    char name[1024] = "(nil)";
    if (key) CFStringGetCString(key, name, sizeof(name), kCFStringEncodingUTF8);
    flockfile(output);
    fprintf(output, "%d %s %s\n", getpid(), call, name);
    fflush(output);
    if (traces++ < 24) {
        void *frames[18]; int count = backtrace(frames, 18);
        backtrace_symbols_fd(frames, count, fileno(output));
    }
    funlockfile(output);
}
static void tracedSetApp(CFStringRef key, CFPropertyListRef value, CFStringRef app) {
    record("CFPreferencesSetAppValue.key", key); record("domain", app);
    CFPreferencesSetAppValue(key, value, app);
}
static void tracedSet(CFStringRef key, CFPropertyListRef value, CFStringRef app, CFStringRef user, CFStringRef host) {
    record("CFPreferencesSetValue.key", key); record("domain", app);
    CFPreferencesSetValue(key, value, app, user, host);
}
static Boolean tracedSync(CFStringRef app) {
    record("CFPreferencesAppSynchronize.domain", app);
    return CFPreferencesAppSynchronize(app);
}
#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new; const void *old; } pair_##original \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original };
INTERPOSE(tracedSetApp, CFPreferencesSetAppValue)
INTERPOSE(tracedSet, CFPreferencesSetValue)
INTERPOSE(tracedSync, CFPreferencesAppSynchronize)

@interface NSUserDefaults (NoctTrace)
- (void)noct_trace_setObject:(id)object forKey:(NSString *)key;
- (void)noct_trace_removeObjectForKey:(NSString *)key;
- (void)noct_trace_setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name;
- (void)noct_trace_removePersistentDomainForName:(NSString *)name;
@end
@implementation NSUserDefaults (NoctTrace)
- (void)noct_trace_setObject:(id)object forKey:(NSString *)key {
    record("NSUserDefaults.setObject.key", (__bridge CFStringRef)key);
    [self noct_trace_setObject:object forKey:key];
}
- (void)noct_trace_removeObjectForKey:(NSString *)key {
    record("NSUserDefaults.removeObject.key", (__bridge CFStringRef)key);
    [self noct_trace_removeObjectForKey:key];
}
- (void)noct_trace_setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name {
    record("NSUserDefaults.setPersistentDomain.name", (__bridge CFStringRef)name);
    [self noct_trace_setPersistentDomain:domain forName:name];
}
- (void)noct_trace_removePersistentDomainForName:(NSString *)name {
    record("NSUserDefaults.removePersistentDomain.name", (__bridge CFStringRef)name);
    [self noct_trace_removePersistentDomainForName:name];
}
@end
__attribute__((constructor)) static void start(void) {
    const char *path = getenv("NOCT_PREF_TRACE_FILE");
    if (!path) return;
    int descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (descriptor < 0) return;
    output = fdopen(descriptor, "a");
    record("trace_loaded", NULL);
    Class type = [NSUserDefaults class];
    const char *names[][2] = {
        {"setObject:forKey:", "noct_trace_setObject:forKey:"},
        {"removeObjectForKey:", "noct_trace_removeObjectForKey:"},
        {"setPersistentDomain:forName:", "noct_trace_setPersistentDomain:forName:"},
        {"removePersistentDomainForName:", "noct_trace_removePersistentDomainForName:"}
    };
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Method original = class_getInstanceMethod(type, sel_registerName(names[i][0]));
        Method traced = class_getInstanceMethod(type, sel_registerName(names[i][1]));
        if (original && traced) method_exchangeImplementations(original, traced);
    }
}
