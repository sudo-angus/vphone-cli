# Connect → Shake kills LV-enforcing apps (e.g. Pippit)

The `Connect → Shake` Mach-injection (helper dylib → `motionBegan/Ended`)
works on some targets but **hard-kills others on the spot**. Observed with
Pippit (`com.bytedance.commercepro`): the app dies the instant Shake is
triggered, with **no crash report** generated.

Root cause is **AMFI library validation**, not the injection machinery.
The helper dylib is signed with the CFW team (`DQF6PC5T2P`, "iPhone
Distribution: jiu de") and is **not a platform binary** on this VM. When the
injected shellcode `dlopen()`s it into a target whose main binary is signed
by a *different* team and that enforces `CS_REQUIRE_LV | CS_KILL`, the kernel
rejects the cross-team library and SIGKILLs the process before the dylib's
constructor runs.

---

## Symptoms

- Shake → target app vanishes immediately ("直接 crash").
- `vphoned` log (`/tmp/vp_motion.log`) shows injection **succeeded** end to
  end: candidate picked, container resolved, dylib deployed, slides/`dlopen`/
  `pthread_create_from_mach_thread` resolved, `injected thread=… into pid=…`.
- The helper's own log (`<container>/tmp/vp_shake_helper.log`) **does not
  exist** → the dylib constructor (`on_load`, whose first act is `diag("dylib
  loaded")`) never ran. So the failure is at/inside the `dlopen`, before the
  constructor.
- **No `.ips` anywhere** — not in `…/CrashReporter`, not in `Retired`. Normal
  app crashes on this VM *do* produce `.ips` (MobileSafari, etc.), so crash
  reporting works; a code-signing SIGKILL just doesn't go through the
  exception→ReportCrash path. (`/var/db/diagnostics` is also empty here, so
  the unified log carries no trace either.)

## Evidence

Target (Pippit) code-signing state, read live via `csops(pid,
CS_OPS_STATUS)` over the on-VM rpcserver (port 5910):

```
flags = 0x26003305
      = CS_SIGNED | CS_PLATFORM_BINARY | CS_DYLD_PLATFORM
      | CS_REQUIRE_LV | CS_ENFORCEMENT | CS_KILL | CS_HARD
      | CS_GET_TASK_ALLOW | CS_VALID
```

- `CS_GET_TASK_ALLOW` → `task_for_pid` succeeds (why injection gets that far).
- `CS_REQUIRE_LV` → library validation enforced.
- `CS_KILL | CS_HARD` → any code-signing violation = immediate kill.
- **No `CS_DEBUGGED`**, no `dynamic-codesigning` / `cs.allow-jit` /
  `cs.disable-library-validation` entitlement.
- `jb.pmap_cs_custom_trust = PMAP_CS_APP_STORE`, team = ByteDance.

Helper dylib (`scripts/vphone_shake_helper/vphone_shake.dylib`, embedded into
`vphoned` as `vphone_shake_dylib_data.h`):

```
TeamIdentifier = DQF6PC5T2P            (iPhone Distribution: jiu de)
CDHash (sha256) = 1f39119903816c65a60faf53a89c7ad6d2f2faa5
flags = 0x0                            (not adhoc, not platformized by signature)
entitlements: platform-application=true, com.apple.private.security.no-container=true
```

The `platform-application` entitlement is **not honored** on this VM (the
cdhash isn't in a loaded trustcache), so the dylib is just a team-`DQF6PC5T2P`
binary — not platform.

### The two failure hypotheses, and the experiment that decided it

Identical observations (no helper log, hard kill, no `.ips`) are produced by
*both*:

- **H1** — injected *unsigned shellcode page* execution blocked by pmap_cs
  (target not `CS_DEBUGGED` / not codegen-trusted); dies before `dlopen`.
- **H2** — shellcode runs fine, but `dlopen` of the *cross-team* dylib trips
  library validation in a `CS_REQUIRE_LV` target → kill.

"`dlopen` works fine from rpcserver" does **not** disambiguate: rpcserver is
itself CFW-signed (team `DQF6PC5T2P`), so it loads the helper via the
*same-team* LV path — consistent with either hypothesis.

Decisive test (run from rpcserver against a live Pippit): inject an anonymous
RX page filled with `b .` (0x14000000) and `thread_create_running` a thread on
it — **no dylib involved**:

```
task_for_pid kr=0
mach_vm_allocate / write / mach_vm_protect(RX) kr=0
thread_create_running kr=0   (PC left UNSIGNED — accepted, so this kernel does
                              not enforce PAC on thread-state PC)
→ Pippit SURVIVED, parked thread spinning.   (cleaned up via thread_terminate)
```

Pippit happily executed an **unsigned, attacker-allocated** page. **H1 is
false.** Therefore the killer is **H2: the cross-team dylib `dlopen` →
library-validation kill.**

## Why it "worked before"

Library validation keys off the *target's* team vs the dylib's team (or
platform status). It worked when the verified target either:

- was itself signed with team `DQF6PC5T2P` (same team as the helper → LV
  passes), or
- did not enforce `CS_REQUIRE_LV`.

Pippit is a foreign-team (ByteDance) app *with* library validation, so the
same helper that loads elsewhere is rejected here. Nothing in the Shake code
changed — `a1ee24e` only added `.arch_extension pauth` so the shellcode
compiles on newer toolchains (emitted bytes unchanged); the shellcode + PAC
handoff are correct (verified: the new pthread is started with
`ldp x8,x0,[self,#0x90]; blraaz x8`, i.e. IA-key / disc-0, which matches the
shellcode's `paciza`).

## Fixes (pick one)

1. **Clear library validation on the target before injecting** *(most
   robust, self-contained in `vphoned`)*. In `vp_handle_motion_command`,
   before `inject_dylib`, clear `CS_REQUIRE_LV` (and ideally `CS_KILL`) on the
   target pid — `csops(pid, CS_OPS_CLEAR_LV, …)` if permitted, otherwise a
   kernel write to `proc->p_csflags &= ~(CS_REQUIRE_LV)` via the JB primitive
   (this kernel already doesn't enforce thread-state PAC, so a csflags write
   is in-budget). Works for any foreign-team target.

2. **Platformize the helper via trustcache.** Add the helper cdhash
   (`1f391199…`) to a trustcache loaded on the guest so AMFI treats it as a
   platform binary; platform binaries bypass the team-id LV check. The dylib
   already carries `platform-application`, so it just needs trustcache
   backing. Cleaner conceptually, but the helper is deployed to the app
   container at runtime, so it needs a *dynamically* loadable trustcache, not
   the static CFW one.

3. *(Not viable)* re-signing the helper as the target's team; *(no help)*
   launching the target `CS_DEBUGGED` — `CS_DEBUGGED` does not relax LV.

## Resolution (implemented)

Reworked `scripts/vphoned/vphoned_motion.m` to **stop loading any dylib** and
do the whole gesture in injected shellcode (option 1 from the list above).
Validated live against Pippit over rpcserver before and after wiring it into
the daemon build.

Three-stage shellcode in one injected code page:

1. **OUTER** (raw Mach thread from `thread_create_running`) →
   `pthread_create_from_mach_thread` to spawn INNER. A raw Mach thread has no
   TLS, so it can't call libdispatch/objc directly.
2. **INNER** (real pthread) → `dispatch_async_f(dispatch_get_main_queue(),
   args, MAIN_WORK)`, then **returns** so libpthread reaps it. UIKit is
   main-thread-only; calling `keyWindow` off-main trips a main-thread
   assertion and kills the app (confirmed during bring-up).
3. **MAIN_WORK** (main thread) → pure `objc_msgSend`:
   `app=[UIApplication sharedApplication]`, `win=[app keyWindow]`,
   `fr=[win valueForKey:@"firstResponder"]` (UIWindow exposes the ivar via
   KVC on 26.1, returns nil cleanly when none), `target = fr ?: win`, then
   `motionBegan:`/`motionEnded:` with `UIEventSubtypeMotionShake`.

Key findings that shaped it:

- Executing injected **unsigned** code pages in an LV+KILL app is allowed on
  this research kernel (proven: a benign `b .` thread with an unsigned PC ran
  and the app survived). Only *loading a foreign-team dylib* is fatal.
- `csops(0, CS_OPS_CLEAR_LV, …)` from inside the target **kills** it on this
  kernel (the AMFI hook treats the clear as a violation under CS_HARD/CS_KILL)
  — so the userspace "clear LV then dlopen" idea is a dead end here.
- `thread_terminate(mach_thread_self())` on a `thread_create_running` thread
  **takes the whole task down** on this kernel. OUTER therefore parks in a
  blocking `pause()` (0 CPU) instead. INNER is a real pthread and is reaped by
  returning. Net cost: one idle (blocked) thread per shake — vastly better
  than the previous `b .` busy-loops, and re-injection is per-request (no
  resident per-pid state / SIGUSR2 anymore).

PAC: the two function pointers handed to a callee that authenticates them —
INNER (pthread start routine) and MAIN_WORK (dispatch work fn) — are signed
with `paciza` (IA key, zero discriminator), which is what libpthread
(`blraaz`) and libdispatch expect. Direct calls to shared-cache functions use
plain `blr` (no auth at the call site).

This works on **every** firmware variant, including the Development variant
installed here, because it never asks AMFI to validate a non-platform library.
The helper dylib (`scripts/vphone_shake_helper/`) and its build wiring in
`scripts/vphoned/Makefile` are no longer used by vphoned; the sources are kept
for reference / the JB-variant dlopen path.

**Deploy:** rebuild with `make vphoned` (done — `vm/.vphoned.signed` updated);
the host pushes the new daemon to the guest on the next `vphone-cli` connect,
so relaunch `vphone-cli` (or reboot the VM) to pick it up.

## Repro / inspection notes

All of the above was gathered live over the on-VM **rpcserver** (rpc-project,
`rpcserver_ios`), reachable because `vphone-cli` forwards `--usbmux-forward
5910:5910`:

```py
from rpcclient.client_manager import ClientManager
c = ClientManager().create(mode='tcp', host='127.0.0.1', port=5910)  # SYNC
# csops STATUS / ENTITLEMENTS_BLOB via c.symbols.csops(pid, op, buf, len)
# crash reports: c.reports.crash_reports.list(prefixed="Pippit")
# fs: c.fs.scandir / c.fs.open ; mem: c.peek/c.poke ; calls: c.symbols.<fn>(...)
```
