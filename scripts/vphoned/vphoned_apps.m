/*
 * vphoned_apps — App lifecycle management via private APIs.
 *
 * Uses LSApplicationWorkspace (CoreServices) and FBSSystemService
 * (FrontBoardServices).
 */

#import "vphoned_apps.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <objc/message.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

// libproc prototypes — headers aren't exported in the iOS SDK (see
// vphoned_motion.m, which relies on the same calls for task_for_pid targeting).
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)
#define PROC_ALL_PIDS 1
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer,
                         int buffersize);

// MARK: - Private API Declarations

@interface LSApplicationProxy : NSObject
@property(readonly) NSString *bundleIdentifier;
@property(readonly) NSString *localizedName;
@property(readonly) NSString *shortVersionString;
@property(readonly) NSString *applicationType;
@property(readonly) NSURL *bundleURL;
@property(readonly) NSURL *dataContainerURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// FBSSystemService loaded via dlsym
static Class gFBSSystemServiceClass = Nil;

static BOOL gAppsLoaded = NO;

BOOL vp_apps_load(void) {
  // FrontBoardServices
  void *fbs = dlopen("/System/Library/PrivateFrameworks/"
                     "FrontBoardServices.framework/FrontBoardServices",
                     RTLD_LAZY);
  if (fbs) {
    gFBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
    if (!gFBSSystemServiceClass) {
      NSLog(@"vphoned: FBSSystemService class not found");
    }
  } else {
    NSLog(@"vphoned: dlopen FrontBoardServices failed: %s", dlerror());
  }

  // LSApplicationWorkspace is in CoreServices (already linked)
  Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
  if (!lsClass) {
    NSLog(@"vphoned: LSApplicationWorkspace class not found");
    return NO;
  }

  gAppsLoaded = YES;
  NSLog(@"vphoned: apps loaded (FBS=%s)",
        gFBSSystemServiceClass ? "yes" : "no");
  return YES;
}

// MARK: - Helpers

static pid_t pid_for_app(NSString *bundleID) {
  if (!gFBSSystemServiceClass)
    return 0;
  id service = ((id (*)(Class, SEL))objc_msgSend)(
      gFBSSystemServiceClass, sel_registerName("sharedService"));
  if (!service)
    return 0;
  return ((pid_t (*)(id, SEL, id))objc_msgSend)(
      service, sel_registerName("pidForApplication:"), bundleID);
}

static NSString *state_for_pid(pid_t pid) {
  if (pid > 0)
    return @"running";
  return @"not_running";
}

// MARK: - Terminate Helper

// Poll pidForApplication: until the app is gone or we hit total_ms. Returns
// YES if no FrontBoard-tracked process remains for bundleID.
static BOOL vp_wait_app_gone(NSString *bundleID, int total_ms) {
  const int step_ms = 100;
  for (int waited = 0; waited < total_ms; waited += step_ms) {
    if (pid_for_app(bundleID) <= 0)
      return YES;
    usleep((useconds_t)step_ms * 1000);
  }
  return pid_for_app(bundleID) <= 0;
}

// Resolve the bundle container directory (.../Bundle/Application/<UUID>) for a
// bundle id via LaunchServices. Returns nil if the app has no LS record.
static NSString *vp_bundle_container_dir(NSString *bundleID) {
  if (!bundleID.length)
    return nil;
  LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
  for (LSApplicationProxy *proxy in [ws allInstalledApplications]) {
    if ([proxy.bundleIdentifier isEqualToString:bundleID]) {
      NSString *appPath = proxy.bundleURL.path; // .../<UUID>/Foo.app
      return appPath.length ? appPath.stringByDeletingLastPathComponent : nil;
    }
  }
  return nil;
}

// Scan the process table for processes whose executable belongs to the bundle
// container at containerPath, matched on the unique <UUID> path component. That
// makes the match immune to /var vs /private/var and to the bundle having been
// deleted out from under a live process. SIGKILLs them when doKill is YES.
// Returns the number of matching live processes found this pass.
//
// pidForApplication: only knows about processes FrontBoard still tracks. Once a
// reinstall has pulled the bundle/registration out from under a live process,
// FrontBoard loses the pid<->bundle binding and reports pid 0 even though the
// process is still running — an "orphan" that neither pidForApplication: nor the
// iOS app switcher can target. Sweeping by executable path reaps those too.
static int vp_scan_bundle_processes(NSString *containerPath, BOOL doKill) {
  NSString *uuid = containerPath.lastPathComponent;
  if (uuid.length < 16)
    return 0; // not a real per-app container UUID; refuse to match broadly
  NSString *needleStr = [NSString stringWithFormat:@"/%@/", uuid];
  const char *needle = needleStr.fileSystemRepresentation;
  if (!needle)
    return 0;

  int npids_byte = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
  if (npids_byte <= 0)
    return 0;
  int cap = npids_byte / (int)sizeof(pid_t) + 16;
  pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
  if (!pids)
    return 0;
  int got_byte = proc_listpids(PROC_ALL_PIDS, 0, pids, cap * (int)sizeof(pid_t));
  int npids = got_byte / (int)sizeof(pid_t);

  int matched = 0;
  char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
  for (int i = 0; i < npids; i++) {
    pid_t pid = pids[i];
    if (pid <= 1)
      continue;
    if (proc_pidpath(pid, path, sizeof(path)) <= 0)
      continue;
    if (strstr(path, needle) == NULL)
      continue;
    matched++;
    if (doKill) {
      NSLog(@"vphoned: SIGKILL bundle process pid=%d path=%s", pid, path);
      kill(pid, SIGKILL);
    }
  }
  free(pids);
  return matched;
}

void vp_sigkill_processes_under_path(NSString *containerPath) {
  if (containerPath.length == 0)
    return;
  for (int i = 0; i < 30; i++) {
    if (vp_scan_bundle_processes(containerPath, YES) == 0)
      break;
    usleep(100 * 1000);
  }
}

BOOL vp_terminate_app(NSString *bundleID) {
  if (!bundleID.length || !gAppsLoaded)
    return YES;

  // Resolve the bundle container up front, while the LS record is still intact,
  // so we can also reap instances FrontBoard no longer tracks ("orphans").
  NSString *containerDir = vp_bundle_container_dir(bundleID);

  // 1. FrontBoard-tracked instance: ask for graceful termination, then escalate.
  pid_t pid = pid_for_app(bundleID);
  if (pid > 0) {
    if (gFBSSystemServiceClass) {
      id service = ((id (*)(Class, SEL))objc_msgSend)(
          gFBSSystemServiceClass, sel_registerName("sharedService"));
      if (service) {
        ((void (*)(id, SEL, id, int, BOOL, id))objc_msgSend)(
            service,
            sel_registerName(
                "terminateApplication:forReason:andReport:withDescription:"),
            bundleID, 5, NO, @"vphoned terminate");
      }
    }
    if (!vp_wait_app_gone(bundleID, 3000)) {
      // SIGTERM is routinely ignored by an app's runloop; only SIGKILL from root
      // is guaranteed. Loop and re-fetch the pid in case FrontBoard re-reports
      // it briefly during teardown.
      for (int i = 0; i < 30; i++) {
        pid = pid_for_app(bundleID);
        if (pid <= 0)
          break;
        kill(pid, SIGKILL);
        usleep(100 * 1000);
      }
    }
  }

  // 2. Reap any process still executing out of the bundle container, including
  //    orphans that pidForApplication: can no longer see.
  if (containerDir.length)
    vp_sigkill_processes_under_path(containerDir);

  // 3. Verdict: nothing FrontBoard-tracked AND nothing left under the bundle.
  BOOL fbAlive = pid_for_app(bundleID) > 0;
  BOOL pathAlive =
      containerDir.length > 0 && vp_scan_bundle_processes(containerDir, NO) > 0;
  return !fbAlive && !pathAlive;
}

// MARK: - Command Handler

NSDictionary *vp_handle_apps_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (!gAppsLoaded) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"apps not available";
    return r;
  }

  // -- app_list --
  if ([type isEqualToString:@"app_list"]) {
    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSArray *allApps = [ws allInstalledApplications];
    NSString *filter = msg[@"filter"] ?: @"all";

    NSMutableArray *result = [NSMutableArray array];
    for (LSApplicationProxy *proxy in allApps) {
      NSString *appType = proxy.applicationType;
      BOOL isSystem = [appType isEqualToString:@"System"];

      if ([filter isEqualToString:@"user"] && isSystem)
        continue;
      if ([filter isEqualToString:@"system"] && !isSystem)
        continue;

      pid_t pid = pid_for_app(proxy.bundleIdentifier);

      if ([filter isEqualToString:@"running"] && pid <= 0)
        continue;

      [result addObject:@{
        @"bundle_id" : proxy.bundleIdentifier ?: @"",
        @"name" : proxy.localizedName ?: @"",
        @"version" : proxy.shortVersionString ?: @"",
        @"type" : isSystem ? @"system" : @"user",
        @"state" : state_for_pid(pid),
        @"pid" : @(pid > 0 ? pid : 0),
        @"path" : proxy.bundleURL.path ?: @"",
        @"data_container" : proxy.dataContainerURL.path ?: @"",
      }];
    }

    NSMutableDictionary *r = vp_make_response(@"app_list", reqId);
    r[@"apps"] = result;
    return r;
  }

  // -- app_launch --
  if ([type isEqualToString:@"app_launch"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    LSApplicationWorkspace *ws = [LSApplicationWorkspace defaultWorkspace];
    NSString *url = msg[@"url"];

    BOOL ok;
    if (url) {
      // Open URL (which will launch the handling app)
      NSURL *nsurl = [NSURL URLWithString:url];
      // Try openURL:withOptions: if available
      SEL openURLSel = sel_registerName("openURL:withOptions:");
      if ([ws respondsToSelector:openURLSel]) {
        ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, openURLSel, nsurl,
                                                       nil);
      } else {
        ok = [ws openApplicationWithBundleID:bundleID];
      }
    } else {
      ok = [ws openApplicationWithBundleID:bundleID];
    }

    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = [NSString stringWithFormat:@"failed to launch %@", bundleID];
      return r;
    }

    // Brief wait for app to start
    usleep(500000); // 500ms

    pid_t pid = pid_for_app(bundleID);
    NSMutableDictionary *r = vp_make_response(@"app_launch", reqId);
    r[@"ok"] = @YES;
    r[@"pid"] = @(pid > 0 ? pid : 0);
    return r;
  }

  // -- app_terminate --
  if ([type isEqualToString:@"app_terminate"]) {
    NSString *bundleID = msg[@"bundle_id"];
    if (!bundleID) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing bundle_id";
      return r;
    }

    BOOL terminated = vp_terminate_app(bundleID);

    NSMutableDictionary *r = vp_make_response(@"app_terminate", reqId);
    r[@"ok"] = @(terminated);
    if (!terminated) {
      r[@"error"] = @"process still running after terminate attempts";
    }
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown apps command: %@", type];
  return r;
}
