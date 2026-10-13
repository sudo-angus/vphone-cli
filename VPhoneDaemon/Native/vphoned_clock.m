/*
 * vphoned_clock — hand timed the Mac's time.
 *
 * timed owns the wall clock while Set Automatically is on. It keeps a filter
 * from the kernel's monotonic clock to UTC, feeds it from its time sources
 * and calls settimeofday itself; a clock set behind its back is put back the
 * next time the filter is applied. A time is offered through CoreTime's
 * TMSetSourceTime, which timed accepts from a client with com.apple.timed
 * whose com.apple.timed.sources lists the source. Neither function is in the
 * SDK.
 *
 * CoreTime's getter waits for timed with no timeout, so each call runs on a
 * queue of its own: a timed that never answers costs a thread, not the caller.
 *
 * See Research/Guest/host_clock_sync.md.
 */

#import "Include/VphonedNative.h"

#include <dlfcn.h>

static BOOL runWithin(int64_t seconds, dispatch_block_t work) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        work();
        dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC)) == 0;
}

static void *coreTimeSymbol(const char *name) {
    void *coreTime = dlopen("/System/Library/PrivateFrameworks/CoreTime.framework/CoreTime", RTLD_NOW);
    return coreTime ? dlsym(coreTime, name) : NULL;
}

int vp_clock_automatic(void) {
    bool (*isEnabled)(void) = coreTimeSymbol("TMIsAutomaticTimeEnabled");
    if (!isEnabled) return -1;
    __block bool enabled = false;
    if (!runWithin(3, ^{ enabled = isEnabled(); })) return -2;
    return enabled ? 1 : 0;
}

int vp_clock_set_automatic(bool enabled) {
    // timed takes this command without a reply; the caller reads it back.
    void (*setEnabled)(bool) = coreTimeSymbol("TMSetAutomaticTimeEnabled");
    if (!setEnabled) return -1;
    if (!runWithin(3, ^{ setEnabled(enabled); })) return -2;
    return 0;
}

int vp_clock_offer(double unixTime, double uncertainty) {
    // timed takes this command without a reply; the caller reads the clock.
    void (*setSourceTime)(CFStringRef, CFAbsoluteTime, CFTimeInterval) = coreTimeSymbol("TMSetSourceTime");
    if (!setSourceTime) return -1;
    CFAbsoluteTime time = unixTime - kCFAbsoluteTimeIntervalSince1970;
    if (!runWithin(3, ^{ setSourceTime(CFSTR("NTP"), time, uncertainty); })) return -2;
    return 0;
}
