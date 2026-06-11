# VZ vsock-device wedge after burst of failed `device.connect()`

Sporadic startup failure: control channel (vsock port 1337) handshake
times out forever, even though `vphoned` on the guest is fully up and
responding. Root cause is on the **host** side — the
`com.apple.Virtualization.VirtualMachine` helper's virtio-vsock state
gets wedged when a burst of `VZVirtioSocketDevice.connect(toPort:)`
calls all fail with `ECONNRESET` in rapid succession before the guest
listener exists. After the wedge, guest→host data delivery is dropped
on the floor for the entire VM lifetime; host→guest still works.

Related but distinct from c3ea826 (`socks5: stop double-closing vsock
fd`), which trips the same VZ helper subsystem from a different
direction (concurrent splice + double `close()` on `conn.fileDescriptor`).

---

## Symptoms

- `vphone-cli` window opens; touch works (VZ USB touchscreen path,
  independent of vphoned).
- Toolbar subtitle shows `disconnected`, no guest IP.
- The wedge surfaces in **one of two host-side fingerprints** (both are the
  same VZ-helper corruption, seen from different points in the connect path):
  - **(a) handshake stall** — `device.connect()` *succeeds*, but the guest→host
    direction is dropped, so the handshake never completes:
    ```
    [control] vphoned binary: .vphoned.signed (305952 bytes, eae9b876544a...)
    [control] handshake timed out after 8s
    [control] connection lost; reconnecting in 3s...
    ```
  - **(b) connect-callback dropped** — `device.connect(toPort:)`'s completion
    handler is *never invoked at all*. Because the reconnect loop only re-arms
    from inside that handler, it goes **silent** — no `connect failed`, no
    `reconnecting`, no `handshake` line — until something external notices:
    ```
    [control] vphoned binary: .vphoned.signed (225152 bytes, ac53b64f4092...)
    (…no further [control] output for ~100 s, until the manager restarts it)
    ```
    A *healthy* connect to a non-listening guest fails with ECONNRESET in ~1 ms,
    so a connect call outstanding for seconds is itself the wedge signature. This
    is the surface seen in the 2026-06 reproduction below.
- `Self.shutdownSocket(fd:)` followed by `disconnect` runs every cycle (surface a).
- **Restarting the VM does not fix it.** Only restarting the host (or
  killing `com.apple.Virtualization.VirtualMachine`) clears the wedge.

## Trigger

A host-side TCP client is hitting the SOCKS5 bridge
(`127.0.0.1:1080`) before vphoned in the guest is ready to accept on
vsock port 1340. Concrete reproducer that has hit it twice:

1. Browser tab open to a page that the user routes through the SOCKS5
   proxy and which keeps issuing background requests (analytics, WS
   keepalive, polling).
2. Launch `make boot`. The bridge starts listening on `127.0.0.1:1080`
   the moment the Swift host comes up — but iOS is still in iBoot →
   kernel → launchd → LaunchDaemons, so `vphoned` won't be listening on
   vsock 1340 for ~10–20 s.
3. During that window, every browser request is accepted on
   `127.0.0.1:1080`, parsed, and dispatched to
   `device.connect(toPort: 1340)`. All fail with
   `NSPOSIXErrorDomain Code=54 "Connection reset by peer"`.

## Evidence chain (one reproduction)

### Host log (`host_output_disconnected.txt`)

Bridge starts listening early:
```
104:[socks5] bridge listening on 127.0.0.1:1080 → guest vsock tcp=1340 udp=1341
108:[hostctl] listening on /Users/angus/workspace/OpenSource/vphone-cli/vm/vphone.sock
```

Burst of failed vsock connects to guest port 1340 while iOS is still
booting (truncated — repeats many times):
```
923:[socks5-diag] vsock connect to port 1340 failed: Code=54 "Connection reset by peer"
988:[socks5] CMD=CONNECT atyp=0x3
989:[socks5] vsock connect failed:        Code=54 "Connection reset by peer"
996,1000,1008,1016,1018,1029,1032: (same)
```

One control handshake on vsock 1337 actually succeeds (this is the v1
vphoned binary the guest had pre-update — connection happens to fall in
a window before the wedge fully manifests):
```
1050:[control] vphoned binary: .vphoned.signed (305952 bytes, eae9b876544a...)
1051:[control] connected to vphoned v1 (192.168.64.73), caps: [...]
1052:[control] pushing update (305952 bytes)...
1053:[control] update sent, waiting for ack...
1054:[vphoned] ok: updated, restarting
1055:[control] read loop ended
1056:[control] connection lost; reconnecting in 3s...
```

After the post-update reconnect, every handshake attempt times out:
```
1104:[control] vphoned binary: .vphoned.signed (305952 bytes, eae9b876544a...)
1105:[control] handshake timed out after 8s
1106:[control] connection lost; reconnecting in 3s...
1107,1113,1116,1125,1128: (same pattern, infinite loop)
```

### Guest log (`/var/root/Library/Caches/vphoned-boot.log`, pid=405)

The same reconnect window on the guest side — every retry the guest
runs the full handshake responder and writes the hello reply in ~1 ms:

```
1779284446.320  accept: got client fd=72
1779284446.365  handle_client: enter fd=72, reading hello
1779284446.366  handle_client: hello received               ← host→guest OK
1779284446.366  handle_client: hashing self for update check
1779284446.366  handle_client: self-hash done (selfHash=eae9b876…)
1779284446.367  handle_client: querying primary_ipv4_address
1779284446.367  handle_client: ip=192.168.64.73
1779284446.367  handle_client: writing hello response (caps=11)
1779284446.367  handle_client: hello response sent OK      ← guest write returned YES
1779284454.719  accept: waiting                            ← +8.3 s: host SHUT_RDWR'd the fd
                                                              after its 8 s timer fired,
                                                              guest's vp_read_message
                                                              returned nil, handler closed
                                                              fd, back to accept loop
```

The 11-entry block above repeats verbatim for **80** consecutive
handshake attempts in this run. Every one of them ends in "hello
response sent OK" within ~1 ms of accept, and the self-hash
(`eae9b876…`) matches the bin_hash the host advertises — so the guest
correctly does not even request another update. The bytes are in the
guest kernel's vsock send queue. They never reach the host's read.

### Direction asymmetry

| Direction       | Status     | Proof                                           |
| --------------- | ---------- | ----------------------------------------------- |
| host  → guest   | OK         | guest logs `handle_client: hello received`      |
| guest → host    | **stuck**  | host's blocking `Self.readMessage` returns 0    |
|                 |            | only after host-side SHUT_RDWR fires from the   |
|                 |            | 8 s timer (kernel-driven EOF, not data)         |

## Root-cause hypothesis

`VZVirtioSocketDevice.connect(toPort:)` is implemented in the VZ helper
process (`com.apple.Virtualization.VirtualMachine`). Each call, success
or failure, traverses virtio-vsock state: allocate a local port,
publish a control-vq message to the guest, wait for guest reply or
reset, then either hand back a connected fd or fail.

When the guest has no listener on the requested port, the guest kernel
sends a `VIRTIO_VSOCK_OP_RST`. The helper must:

1. Reap its internal connection record (port table, refcounts).
2. Surface `ECONNRESET` to the API caller.

We do not have source for the helper, but the empirical fingerprint
matches a leak / corruption in step 1 under concurrent pressure:

- After ~20 concurrent rapid-fail connects, **all subsequent
  guest→host vsock data delivery is silently dropped** for the VM.
- Host→guest still works (we still drive control-vq messages out).
- Only re-initializing the helper process clears it.

This is the same family of defects as c3ea826 (`socks5: stop
double-closing vsock fd`), which observed the helper's
`virtio.vsock-device` assertion firing under sustained SOCKS5 load. The
fix there was to stop racing with the helper's fd lifecycle. This bug
sits one layer up: the helper's port table itself drifts when too many
failed connects retire concurrently.

## Why VM restart doesn't help

The corrupted state is in the host helper process, **not** in the
guest kernel and not on the VM disk. `make boot` (or any VM relaunch
that reuses the same helper) inherits the wedge. Killing the VZ helper
— or rebooting the host — is required.

(Note: each `make boot` does spawn a fresh helper, so a fresh `make
boot` after closing the previous one should also recover. But in this
reproducer the bridge starts listening *before* the previous helper has
fully been torn down — or the new helper is hit by the same browser
burst before vphoned comes up — and we just walk back into the wedge.)

## Mitigation status

Implemented:

1. **Defer SOCKS5 listening until `VPhoneControl.onConnect` has fired.**
   This avoided the VZ helper wedge, but it exposed a worse UX: some proxy
   clients cache early `ECONNREFUSED` and then retry only after a long backoff
   (observed up to ~10 minutes).

2. **Current fix: keep the local SOCKS5 listener up, gate only the guest
   backend.** `VPhoneAppDelegate` starts the `127.0.0.1:<port>` listener as
   soon as the VM exposes its virtio socket device (so clients never hit a
   local `ECONNREFUSED` and back off). The gate itself lives in
   `VPhoneSocks5Bridge`: a lock-guarded `BackendReadyFlag`, flipped via
   `setBackendReady(_:)`. `VPhoneAppDelegate` wires `VPhoneControl.onConnect`
   → `setBackendReady(true)` and `onDisconnect` → `setBackendReady(false)`, in
   both the windowed and headless branches. Because `onConnect` only fires on a
   *post-update* control connection (see `performHandshake`: a `need_update`
   session pushes the binary and never calls `onConnect`; the gate opens only
   after vphoned has restarted and re-handshaked clean), a pre-update control
   connection cannot prematurely open the gate. While the flag is clear,
   CONNECT / UDP ASSOCIATE requests get a quick SOCKS5 host-unreachable reply
   (`rep=0x04`) and, critically, the bridge does **not** call
   `device.connect(toPort: 1340/1341)`. This kills the early-ECONNRESET burst at
   the source while avoiding local-port refusal/backoff behavior.

   > History: this mitigation was *described* here before it existed in code —
   > the SOCKS5 UDP-ASSOCIATE rewrite (`abc5408`) shipped a bridge with no
   > readiness gate, so the wedge resurfaced specifically on GUI-manager
   > launches (the supervisor execs the child instantly, maximizing the odds a
   > host SOCKS5 client floods `:1080` during the iOS boot window; `make boot`
   > merely dodged it by luck of timing). The gate above is the actual landed
   > implementation.

3. **Manager-side self-heal on detection (landed).** The readiness gate
   above only covers the SOCKS5 path; on a `--tcp-workaround` (or plain
   control-only) GUI-manager launch the wedge can still occur — observed
   on a fresh iOS 26.5 VM whose ~80 s first boot widened the
   failed-connect window (guest `accept: errno=53` on *every* accept, 0
   successful; host `reset by peer` forever). The manager now recovers
   automatically: `VPhoneHealthMonitor` already probes each VM's
   `vphone.sock` and distinguishes "host app alive, guest vsock down"
   (`connected:false` → `.guestDisconnected`) from a still-booting guest.
   When that state persists past `guestDownThreshold` (40 × 3 s ≈ 120 s,
   generous enough to clear the slowest first boot) it fires
   `onWedgeSuspected`. `VPhoneManagerModel.autoHealWedge` then does a full
   child restart (new process → **new helper**, which clears the wedge),
   bounded to `maxAutoHeals` (2) attempts per run; a fresh helper that
   still wedges means the host itself needs a restart, so it falls back to
   a manual `restartPrompt` rather than looping. Every action is logged to
   the VM's console buffer. This is the `make boot`-recovers-by-luck path
   from "Why VM restart doesn't help", made deterministic.

5. **Connect watchdog + fast wedge signal (landed).** Mitigation #3 keys off
   `guestDownThreshold` (~120 s), generous so it never kills a slow boot. But the
   **connect-callback-dropped** surface (symptom *b*) has a signature a slow boot
   never produces — the connect call hangs instead of failing promptly — so it
   can be recovered far sooner without risking a false positive on a slow boot.
   - `VPhoneControl.armConnectTimeout` arms an 8 s watchdog per
     `device.connect(toPort:)`. Whichever of the completion handler or the
     watchdog runs first settles the attempt (`currentConnectResolved`); a dropped
     callback becomes a *counted* failure that reschedules the reconnect, so the
     loop never silently stalls.
   - `VPhoneControl.vsockStallStreak` counts consecutive **wedge-shaped** failures
     — connect-callback dropped, handshake timeout, or handshake no-response —
     and resets to 0 on a clean connect. A prompt ECONNRESET (booting guest)
     deliberately leaves it untouched, so the streak only climbs under a real
     wedge.
   - The streak rides the existing `vphone.sock` health reply as `vsock_stall`.
     `VPhoneHealthMonitor` fires `onWedgeSuspected` as soon as it reaches
     `wedgeStallThreshold` (2 ≈ ~20 s) — debounced per episode via `wedgeFired` —
     instead of waiting out `guestDownThreshold`. Both wedge surfaces (a *and* b)
     raise the streak, so both now recover fast; everything else still falls back
     to the slow ~120 s guest-down path.
   - **Does not eliminate the wedge** (that lives in Apple's closed helper) — it
     makes detection deterministic and ~6× faster, and never touches the local
     `:1080` listener, so it cannot reintroduce the mitigation-#1 backoff stall.

Still available if this resurfaces:

4. **Throttle / serialize `device.connect(toPort:)`.** A serial
   `DispatchQueue` for the vsock connect step, with a short backoff on
   `ECONNRESET`. Doesn't fully prevent the wedge if a single client
   reconnects fast enough, but cuts the failure rate dramatically. Would
   complement the self-heal by reducing how often it has to trigger.

## Reproduction 2026-06 (GUI manager, connect-callback-dropped surface)

A clean instance captured from the GUI manager's per-VM console buffer, notable
because it is **not** the SOCKS5-burst trigger the doc was written around — the
readiness gate (mitigation #2) was working correctly.

Timeline across one rolling console buffer (three child launches):

1. Launch #1 connects fine (`connected to vphoned v1 (…64.150)`), runs, then a
   user `SIGINT` restart hands off to launch #2 *instantly* (GUI supervisor).
2. Launch #2 wedges. Its control channel makes the usual boot-window connect
   attempts — six prompt `connect failed: …Code=54 "Connection reset by peer"`
   each followed by `reconnecting in 3s` (normal: guest not listening yet) — then
   the **seventh** attempt logs only its `vphoned binary:` line and goes silent.
   `device.connect(toPort: 1337)`'s completion handler was never called again;
   the loop stalled for ~100 s.
3. `VPhoneHealthMonitor` (host app alive, `connected:false` for ~120 s) fires
   `onWedgeSuspected`; `autoHealWedge` restarts into launch #3 (attempt 1/2).
4. Launch #3 gets a fresh helper, rides out its boot window, and connects
   (`connected to vphoned v1 (…64.153)` — note the new guest IP).

Key points that shaped mitigation #5:

- The SOCKS5 gate held: launch #2's `onConnect` never fired (control never came
  up), so the gate stayed closed and the bridge issued **zero** `device.connect`
  on 1340/1341 — no `[socks5] vsock connect` lines. The trigger was **not** a
  browser SOCKS5 burst.
- 6–8 boot-window ECONNRESETs is *normal* — launches #1 and #3 had the same count
  and connected. So this is a low-probability race in the helper's
  connect/reset reaping, consistent with the root-cause hypothesis, not a
  deterministic connect-count threshold.
- The only thing that noticed the silent stall was the manager's slow 120 s
  timer — which is exactly the gap mitigation #5 closes.

## Historical reproducer

This describes the pre-readiness-gate behavior, where the local listener was
up and every early client request immediately attempted a guest vsock connect.
Requires an affected vphone-cli build, a previously installed CFW disk, and a
SOCKS5-enabled browser.

1. In any browser, configure SOCKS5 proxy = `127.0.0.1:1080`. Open a
   tab to a page with continuous background requests (Twitter, Gmail,
   any analytics-heavy site). Leave the tab focused so it doesn't
   throttle.
2. `make boot`. On affected builds, the bridge starts listening immediately
   and the browser tab begins firing `device.connect` calls while iOS is still
   booting.
3. Wait for `[control] connected to vphoned v1 …` followed by the
   update push.
4. After `[control] read loop ended`, watch for an infinite stream of
   `[control] handshake timed out after 8s`.

Confirmation that it's the guest-side that is healthy:

```sh
# from another shell on host, while the wedge is happening:
# (uses the MCP push_file path via vphone-cli's daemon — but the
# daemon's control channel is wedged too, so use pull_file from a
# separate MCP session, which goes through a different vsock port
# that may still work)
mcp__vphone__pull_file /var/root/Library/Caches/vphoned-boot.log \
                       /tmp/vphoned-boot.log
```

The pulled log will show many `handle_client: hello response sent OK`
entries during the wedge — proving guest-side is fine.

Recovery from the wedge (without code changes):

- Close all SOCKS5-using clients (the browser tab).
- Quit `vphone-cli`.
- Relaunch. If the helper survived as a daemon, the wedge will follow;
  in that case restart the host machine. After restart, launch
  `vphone-cli` **before** opening the browser tab, let vphoned connect
  cleanly, then enable the browser proxy.
