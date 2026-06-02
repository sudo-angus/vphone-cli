/*
 * vphoned_apps — App lifecycle management over vsock.
 *
 * Handles app_list, app_launch, app_terminate, app_foreground using
 * private APIs: LSApplicationWorkspace, FBSSystemService, SpringBoardServices.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load private framework symbols for app management. Returns NO on failure.
BOOL vp_apps_load(void);

/// Handle an app command. Returns a response dict.
NSDictionary *vp_handle_apps_command(NSDictionary *msg);

/// Terminate a running app by bundle ID, reliably and by bundle ID alone.
/// Handles both the FrontBoard-tracked case (graceful terminate, then SIGKILL)
/// and "orphans" that pidForApplication: can no longer see (swept by matching
/// the app's unique bundle-container UUID against the process table). Returns
/// YES only if no process for the app remains afterwards.
BOOL vp_terminate_app(NSString *bundleID);

/// Hard-kill any process whose executable belongs to the bundle container at
/// containerPath (matched on its unique <UUID> component). Used to reap orphaned
/// instances after the bundle was deleted/re-registered out from under them.
void vp_sigkill_processes_under_path(NSString *containerPath);
