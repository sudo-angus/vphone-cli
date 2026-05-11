/*
 * vphone_shake — helper dylib injected into user apps by vphoned.
 *
 * Each dlopen runs the constructor: log the load and fire one
 * UIEventSubtypeMotionShake at the current first responder.
 *
 * Repeat shakes are handled by sending SIGUSR2 from vphoned — the signal
 * handler installed here dispatches another shake on the main queue.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static void diag(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"[vphone_shake] %s", buf);
    FILE *fp = fopen("/tmp/vp_shake_helper.log", "a");
    if (fp) {
        fprintf(fp, "pid=%d %s\n", getpid(), buf);
        fclose(fp);
    }
}

static UIView *find_first_responder(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *sub in view.subviews) {
        UIView *fr = find_first_responder(sub);
        if (fr) return fr;
    }
    return nil;
}

static void fire_shake_now(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) { diag("no UIApplication"); return; }

    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
            if (keyWindow) break;
        }
    }
    if (!keyWindow) {
        for (UIWindow *w in app.windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
    }
    if (!keyWindow && app.windows.count > 0) keyWindow = app.windows.firstObject;
    if (!keyWindow) { diag("no keyWindow"); return; }

    UIView *fr = find_first_responder(keyWindow);
    diag("firing motionShake on %s",
         fr ? object_getClassName(fr) : object_getClassName(keyWindow));
    UIResponder *target = fr ?: (UIResponder *)keyWindow;
    [target motionBegan:UIEventSubtypeMotionShake withEvent:nil];
    [target motionEnded:UIEventSubtypeMotionShake withEvent:nil];
}

static void schedule_shake(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        fire_shake_now();
    });
}

static void on_sigusr2(int sig) {
    // dispatch_async is async-signal-safe per Apple docs.
    schedule_shake();
}

__attribute__((constructor))
static void on_load(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        diag("dylib loaded");
        struct sigaction sa = {0};
        sa.sa_handler = on_sigusr2;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGUSR2, &sa, NULL);
        diag("SIGUSR2 handler installed");
    });
    // Don't fire shake here — vphoned always sends SIGUSR2 right after
    // inject, which works for both fresh loads (constructor runs) and
    // cached loads (constructor skipped, but signal handler is already in
    // place from a previous load).
}
