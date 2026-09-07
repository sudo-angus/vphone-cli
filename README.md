<div align="right"><strong><a href="./docs/README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./docs/README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./docs/README_zh.md">🇨🇳中文</a></strong> | <strong>🇬🇧English</strong></div>

# vphone-cli

Boot a virtual iPhone via Apple's Virtualization.framework using PCC research VM infrastructure.

![poc](./docs/demo.jpeg)

## Prerequisites

**Host:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK (cross-compiles the guest daemon)
- [SIP/AMFI relaxation to allow private PV=3 entitlements with unsigned-binary](#sipamfi-relaxation)

**Dependencies:**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## Install

```bash
brew install zqxwce/tap/vphone-cli
```

## Build

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # install deps, build toolchain submodules, create the Python venv
./scripts/build.sh            # build + sign vphone-cli, bundle the .app, cross-compile vphoned

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

## Quick Start

One command creates a VM end-to-end (download → patch → DFU restore → CFW install → first boot):

```bash
vphone-cli vm create myphone -V jb        # -V / --variant

vphone-cli vm launch myphone
```

## Commands

`vphone-cli vm create` runs the whole pipeline; the individual steps below let you drive it manually or re-run one stage.

### Manage

```bash
vphone-cli vm list                         # list VMs (--json for scripting)
vphone-cli vm info myphone                  # show one VM
vphone-cli vm new myphone                   # create an empty bundle (cpu/mem/disk options)
vphone-cli vm config myphone --cpu 8 --memory 8192
vphone-cli vm clone myphone myphone-2       # fast APFS clone, fresh device identity
vphone-cli vm export myphone --out myphone.tzst   # zstd fast by default (--max = xz -9); --out may be a dir (auto-names <vm>.tzst/.txz); skips restore dir + staging files
vphone-cli vm import myphone.tzst --name restored
vphone-cli vm rename myphone iphone16
vphone-cli vm delete iphone16
```

### Build a VM manually (what `vm create` automates)

```bash
vphone-cli vm new myphone                              # 1. empty bundle
vphone-cli fw prepare myphone --iphone-version 26.1     # 2. download + merge IPSWs
vphone-cli fw patch myphone --variant jb                # 3. patch the boot chain

vphone-cli vm launch myphone --dfu &                    # 4. boot into DFU (background)
vphone-cli restore myphone --get-shsh                   #    fetch SHSH
vphone-cli restore myphone                              #    DFU restore
vphone-cli vm stop myphone                              #    stop the DFU boot

vphone-cli cfw install myphone --variant jb             # 5. install CFW (host-mount; asks for sudo)
vphone-cli vm launch myphone                            # 6. first boot
```

Update to a newer iOS by pointing `fw prepare` at an IPSW: `--iphone-source /path/to.ipsw --cloudos-source /path/to.ipsw`.

## Firmware Variants

Five patch variants with increasing security bypass — pass one to `--variant`:

| Variant      | Boot Chain  | CFW       | Notes                                                              |
| ------------ | ----------- | --------- | ----------------------------------------------------------------- |
| `less`       | 4 patches   | 2 phases  | Patchless — keeps iOS mitigations enabled                         |
| `regular`    | 42 patches  | 10 phases | AMFI/SSV/Img4/TXM bypass                                           |
| `dev`        | 53 patches  | 12 phases | + TXM entitlement/debug bypass                                    |
| `jb`         | 113 patches | 14 phases | + full jailbreak (Sileo, TrollStore auto-install on first boot)   |
| `exp`        | 141 patches | 18 phases | JB superset + anti-VM-detection research patches                  |

See [`research/0_binary_patch_comparison.md`](./research/0_binary_patch_comparison.md) for the per-component breakdown.

## Running & Connecting

- **SSH (jailbreak):** `ssh -p 22222 mobile@<vm-ip>` (password `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## VM Manager (GUI)

Instead of driving VMs from the terminal, you can use the **VPhone** manager — a
Dock app that lists every VM, starts/stops/restarts them, monitors guest health,
captures per-VM logs, and authorizes the AMFI bypass once via a scoped sudoers
rule.

```bash
make install_app   # one-shot: submodules + tools + build + /Applications launcher
```

This is the only command a fresh clone needs for the GUI entry. It is idempotent
— it initializes the vendor SPM submodules, runs `setup_tools` once if host tools
are missing (`ldid`, venv), builds and ad-hoc-signs the bundles, copies the app
to `/Applications/VPhone.app`, and indexes it so it shows up in Spotlight /
Launchpad / Dock. It then offers to launch the app (just press Enter). No `sudo`
(`/Applications` is admin-writable) and no Apple Developer account (ad-hoc
signing on an AMFI-disabled host).

It installs a real copy, not a symlink — Spotlight and Launchpad skip symlinked
bundles, so they would never surface in search. The copied manager records this
clone's path inside the bundle and always spawns the entitled boot binary from
your live build, so day-to-day `make build` needs no re-install; re-run
`make install_app` only to refresh the manager binary itself.

On first launch the window shows a highlighted **Authorize admin** banner —
click it once to install the scoped sudoers rule, after which VMs can start and
the AMFI bypass runs without a password. Launch the app as **VPhone**, with
`open -a VPhone`, or run `make manage` to open the manager without installing the
launcher. Remove the launcher with `make uninstall_app`.

## Optional Host TCP Workaround

If the host is behind a corporate VPN / traffic-forwarding agent and the guest
loses outbound TCP connectivity under `VZNATNetworkDeviceAttachment()`, pass
`--tcp-workaround` when booting:

```bash
make boot EXTRA_ARGS=--tcp-workaround
```

`vphone-cli` itself stays unprivileged. After the VM has started, it launches
the same helper via `sudo`; bridge detection stays inside
`scripts/vm_tproxy_start.sh`, matching the manual path. `boot.sh` warms the
sudo credential cache before boot so this path is usually silent. Only the
privileged helper (`pfctl` rule install / flush, `/dev/pf` + `DIOCNATLOOK`
queries, and the userspace TCP relay) runs as root. The helper is told the
parent's pid via `WATCH_PID`, so if vphone-cli exits or crashes the helper tears
the `pf` anchor down on its own — no launchd, no leftover rules.

The same helper also serves **guest DNS**. The pf redirect only captures TCP, so
name resolution would otherwise be left to the shared-network gateway — which, in
the VPN environment this workaround exists for, has nothing answering `:53`, so
every lookup hangs and apps read as "no network" even though bare-IP TCP works.
The helper runs a userspace forwarder on `<bridge>:53` (UDP + TCP) that relays to
whatever resolver the *host* is currently using; being a host process, it reaches
the corp resolver through the same VPN. The upstream is re-read on a short TTL, so
a host Wi-Fi/VPN switch is picked up automatically. If something already answers
`:53` on the bridge the forwarder logs the bind conflict and steps aside (the TCP
relay is unaffected); set `ENABLE_DNS=0` to opt out entirely. See
`research/tcp_workaround_guest_dns_forwarder.md`.

Notes:

- This workaround proxies IPv4 TCP and serves IPv4 DNS (UDP + TCP). It does not
  repair other UDP / QUIC traffic.
- The helper inherits the same auto-detection used by the older standalone
  scripts; on a non-standard host you can still override `LISTEN_ADDR` /
  `PF_INTERFACE` via env vars.
- If a helper is already running, the integrated `vphone-cli` path replaces it
  so each boot owns its cleanup. Endpoint detection waits briefly for
  Virtualization's `bridge*` / `vmenet*` interface to appear during clean boots.
- If you prefer to drive the helper outside of `vphone-cli` (e.g. for
  debugging), `scripts/vm_tproxy_start.sh start|stop|status` still works as
  before.

`make boot` can start native usbmux TCP forwarders without Python. Pass one or
more `--usbmux-forward <local>:<guest>` entries through `EXTRA_ARGS`:

```bash
make boot EXTRA_ARGS="--usbmux-forward 2222:22222 --usbmux-forward 5910:5910"
```

This replaces separate `pymobiledevice3 usbmux forward` processes for those
ports. Examples:

```bash
make boot EXTRA_ARGS="--usbmux-forward 2222:22222"  # SSH (dropbear)
make boot EXTRA_ARGS="--usbmux-forward 2222:22"     # SSH (OpenSSH)
make boot EXTRA_ARGS="--usbmux-forward 5910:5910"   # RPC
```

The target is matched by the VM's predicted UDID/ECID; `--usbmux-udid <UDID>`
can override it for unusual setups. If no `--usbmux-forward` is passed, no
native usbmux tunnel is started.

## Locations

Everything vphone-cli creates lives under `~/.vphone/` — kept outside the repo and the `.app` so the signed bundle stays portable. Redirect the whole tree with `$VPHONE_ROOT`:

| Path              | Contents                                                                                     |
| ----------------- | -------------------------------------------------------------------------------------------- |
| `~/.vphone/`      | The per-user data root — override the entire location with `$VPHONE_ROOT`.                   |
| `~/.vphone/VMs/`  | VM bundles — one directory per VM. This is the library; override with `$VPHONE_LIBRARY_ROOT`. |
| `~/.vphone/ipsws/`| Downloaded iPhone + cloudOS IPSWs, cached and reused across VMs.                              |
| `~/.vphone/tools/`| Cached APFS seal-volume artifacts (`apfs_sealvolume_<version>`) fetched during `fw prepare`.  |
| `~/.vphone/debs/` | Cached `.deb` packages the `jb`/`exp` CFW install lays into the guest (Sileo, apt, …).        |
| `~/.vphone/venv/` | Auto-provisioned Python environment (see [Python runtime](#python-runtime); override with `$VPHONE_VENV_DIR`). |

Precedence: the per-item overrides (`$VPHONE_LIBRARY_ROOT`, `$VPHONE_VENV_DIR`) win over `$VPHONE_ROOT`, which wins over the `~/.vphone` default. The `ipsws/`, `tools/`, and `debs/` caches always sit directly under whichever root is active.

## SIP/AMFI Relaxation

**Option A — fully disable SIP, then disable AMFI via boot-arg (most permissive).** 

In Recovery (long-press power → Terminal):

```bash
csrutil disable
csrutil allow-research-guests enable
```

Then reboot into macOS and set the AMFI boot-arg (needs SIP fully off to take effect):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # reboot after
```

**Option B — keep SIP on (debug-only relaxed), then allowlist the binary with amfidont** (leaves AMFI enabled system-wide). 

In Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

Then reboot into macOS and:

```bash
vphone-amfidont         # .build/vphone-cli.app/Contents/Resources/vphone-amfidont for local builds
```

## Tested Environments

| Host            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |

## FAQ

**`zsh: killed ./vphone-cli`** — AMFI/debug restrictions aren't bypassed; see [Prerequisites](#prerequisites) (`amfi_get_out_of_my_way=1` or `amfidont`).

**`Virtualization is not available on this hardware`** — your Mac is itself a VM; PV=3 guest boot can't nest. Use a non-nested macOS 15+ host.

**Stuck on "Press home to continue"** — connect via VNC and right-click (two-finger click) to simulate the home button.

**System apps won't install** — during iOS setup, don't pick Japan or the EU as your region (extra regulatory checks the VM can't satisfy); pick e.g. United States.

**App crashes on launch with `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — re-patch with `vphone-cli fw patch <name> --variant <v> --force-exc-guard`, then re-restore/install ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Always on for iOS 18 bases.

**Install a `.ipa`/`.tipa`** — use the running VM's Install menu (drag-drop or file picker).

**`cfw install` hangs re-signing a system binary (e.g. `Campo`), memory climbing unbounded** — known bug in `ldid-procursus` up to `2.1.5-procursus7` (the current Homebrew `stable`): `bytes(uint64_t)` calls `__builtin_clzll(0)` with no zero-guard, which is undefined behavior, and on this build resolves to a `0`-length that underflows an unsigned loop counter — `ldid` spins writing one byte at a time into a growing buffer instead of terminating. Triggered by *any* entitlements plist containing an integer value of exactly `0` (some real Apple system binaries have these). Fixed upstream but not yet in a tagged release; rebuild from source: `brew install --HEAD ldid-procursus && brew link --overwrite ldid-procursus`. Kill the hung `ldid` process first (`sudo kill -9 <pid>`) if you already hit it.

## Automation

`vphone-cli` exposes a host control socket (`<bundle>/vphone.sock`) for programmatic control — screenshots, touch, swipes, hardware keys, clipboard — each action returning an inline screenshot for AI-driven E2E testing. See [vphone-mcp](https://github.com/pluginslab/vphone-mcp) for an MCP server wrapping it.

## Acknowledgements

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
