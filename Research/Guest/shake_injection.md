# UIKit shake injection

`input.shake` delivers `UIEventSubtypeMotionShake` to an injectable foreground
user app. The VM menu enables Shake only when the guest reports `motion_shake`.
It is independent of the upstream gyroscope and attitude simulation.

The implementation in `VPhoneDaemon/Native/vphoned_motion.m` migrates the local
`6aefd47` implementation. A raw Mach thread starts a pthread, which schedules
UIKit work on the app's main queue. The shellcode calls `motionBegan:` and
`motionEnded:` on the first responder or key window. It does not load a foreign
helper dylib into the target, avoiding that dylib's library-validation failure.

The target must allow `task_for_pid`. Injection failure and absence of a suitable
foreground app are API errors. Each request allocates code/data/stack pages and
leaves one parked Mach thread in the target, as the earlier implementation did;
this is suitable for occasional debugging, not continuous sensor simulation.
The UI event is scheduled asynchronously: an RPC success records successful
injection, not confirmation that the app handled the event.

The source compiles for the iOS arm64 target. Runtime acceptance must be repeated
on the new schema 2 firmware with a development-signed app that visibly responds
to Shake. No event has been injected into the currently running legacy VM during
this migration.
