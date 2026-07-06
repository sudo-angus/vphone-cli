# Guest DNS forwarder for `--tcp-workaround` (VPN/飞连 environments)

Under a corporate VPN / traffic-forwarding agent (飞连), a `--tcp-workaround`
guest boots with working bare-IP TCP but **no name resolution**: apps read as
"no network" while `poke doctor` / install / launch all pass, because those only
exercise the host→guest control plane, not the guest's data-plane DNS.

## Diagnosis (2026-07-06 incident)

Captured from a guest that had lost networking mid-session:

- Guest has an IP (`192.168.64.8`) and the gateway is the host bridge
  (`192.168.64.1`).
- `--tcp-workaround`'s TCP relay is running, so **raw-IP TCP egress works**.
- Name resolution hangs — `neverssl.com` never loads.
- The guest's DHCP lease points DNS at `192.168.64.1`, **but nothing on the host
  is listening on `192.168.64.1:53`.** Queries go to the gateway and are never
  answered.
- (Compounding, seen once: the guest's running `SystemConfiguration` had an empty
  `en0` DNS list and a missing default route — a mid-session flap corruption on
  top of the missing resolver.)

Root cause: the pf redirect the workaround installs is `proto tcp` only (see
`scripts/vm_tproxy_start.sh` → `load_anchor`). DNS is UDP/53 and was never in the
data path. On a normal LAN the shared-network gateway answers `:53`; in this VPN
environment it does not, so the guest is told to use a resolver that is silent.

The manual fix that worked at the time was, on the host, a DNS forwarder on
`192.168.64.1:53 → <corp resolver>:53`, plus re-writing the guest's `en0` DNS to
`192.168.64.1` and restoring its default route.

## Landed fix: forwarder inside the tproxy helper

`scripts/vm_tproxy.py` now runs a userspace DNS forwarder on `<bridge>:53`
(both UDP and TCP), started from `main()` when `--dns` is set (the default;
`scripts/vm_tproxy_start.sh` passes it unless `ENABLE_DNS=0`). It shares the
helper's lifecycle, privilege, and `WATCH_PID` teardown — no new moving parts.

Design points:

- **Upstream = the host's current resolver, read fresh.** `get_upstream_resolvers`
  parses `scutil --dns` (falling back to `/etc/resolv.conf`), cached with a 5 s
  TTL. Because the forwarder is a host process, forwarding to the host's resolver
  reaches the corp DNS through the same VPN the TCP relay already rides. Re-reading
  on a short TTL means a host Wi-Fi/VPN switch is reflected automatically — this is
  also why it addresses the "recover after host network change" ask without any
  host-network-event plumbing.
- **Loop guard.** `_usable_upstream` rejects IPv6, the whole `192.168.64.0/24`
  vmnet subnet, and the bridge itself, so the forwarder can never point back at
  its own listener. Loopback upstreams are allowed (a host-local VPN resolver
  answers correctly from the host).
- **Deconfliction.** If something already answers `:53` on the bridge (a working
  native shared-network resolver), the `bind()` fails with `EADDRINUSE`; the
  forwarder logs and steps aside. The TCP relay is independent and keeps running.
- **UDP is primary; TCP is the TC-bit fallback.** Large answers set the truncated
  bit and clients retry over TCP; the TCP listener relays those via the existing
  `relay()` pump.

Verified locally (2026-07-06): UDP and TCP forwarding both resolve real names
through the host's upstream; `py_compile` / `zsh -n` clean.

## Not yet done (guest-side hardening)

The host forwarder fixes the common case: a clean boot gets DNS=`192.168.64.1` +
default route from DHCP, and now `:53` answers. The **mid-session flap** surface —
guest `en0` DNS cleared / default route dropped after a network transition — is
guest state and is *not* repaired by this change. If it recurs, the fix is for
`vphoned` to re-assert `en0` DNS = gateway and the default route when it detects
loss. Deferred because it is guest-side (ObjC in `scripts/vphoned/`) and cannot be
validated on a host where `--tcp-workaround` is intentionally off; validate the
host forwarder on a corp machine first and only add guest enforcement if the flap
reproduces after it.

## Testing on a corp machine

1. `make boot EXTRA_ARGS=--tcp-workaround` and wait for
   `[tproxy] guest DNS forwarder enabled on 192.168.64.1:53`.
2. In the guest, resolve an internal domain and a public domain (`neverssl.com`),
   and confirm an HTTPS GET on each. Both should now work.
3. Switch the host network (toggle 飞连 / Wi-Fi); within ~5 s new lookups should
   resolve against the new upstream with no guest restart.
