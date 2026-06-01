/*
 * vphoned_motion — fire UIEventSubtypeMotionShake in a target app.
 *
 * Implemented by Mach-injecting pure shellcode (no helper dylib): a raw
 * Mach thread bootstraps a pthread, which dispatch_async_f's onto the main
 * thread and delivers motionBegan:/motionEnded: to the key window's first
 * responder via objc_msgSend. Loading a foreign-team dylib via dlopen()
 * would be killed by AMFI library validation in any app that enforces
 * CS_REQUIRE_LV | CS_KILL; executing injected code pages is not, so the
 * shellcode path works on every firmware variant (not just Jailbreak).
 * See research/shake_inject_killed_by_library_validation.md.
 *
 * Constraints:
 *   - Target must be a dev-signed app (get-task-allow=true). System apps
 *     are rejected by AMFI at task_for_pid time.
 *   - Each request re-injects; there is no resident per-pid state.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Initialize the motion module. Returns NO if anything required is missing.
BOOL vp_motion_load(void);

/// True after a successful vp_motion_load(); used for capability gating.
BOOL vp_motion_available(void);

/// Handle a `{"t":"shake"}` request. Returns an `ok` or `err` response.
NSDictionary *vp_handle_motion_command(NSDictionary *msg);
