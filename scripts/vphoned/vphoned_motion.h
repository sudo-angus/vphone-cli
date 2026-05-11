/*
 * vphoned_motion — fire UIEventSubtypeMotionShake in a target app.
 *
 * Implemented via Mach injection of vphone_shake_helper.dylib (embedded
 * in vphoned at build time, deployed into the target app's own data
 * container at request time to satisfy the sandbox read policy). The
 * helper installs a SIGUSR2 handler that fires the shake event; vphoned
 * triggers it with kill().
 *
 * Constraints:
 *   - Target must be a dev-signed app (get-task-allow=true). System apps
 *     are rejected by AMFI at task_for_pid time.
 *   - First request for a pid does the full inject; subsequent ones are
 *     just SIGUSR2.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Initialize the motion module. Returns NO if anything required is missing.
BOOL vp_motion_load(void);

/// True after a successful vp_motion_load(); used for capability gating.
BOOL vp_motion_available(void);

/// Handle a `{"t":"shake"}` request. Returns an `ok` or `err` response.
NSDictionary *vp_handle_motion_command(NSDictionary *msg);
