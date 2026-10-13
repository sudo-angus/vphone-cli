# Legacy VM import without replacing the device

## Verified findings (2026-10-13)

The local legacy VM is `/Users/angus/workspace/OpenSource/vphone-cli/vm`.
Its manifest has no schema marker. It names `Disk.img`, `nvram.bin`,
`SEPStorage`, and the same AVP/SEP ROM filenames the new runtime uses.
The stored `machineIdentifier` is nonempty and accepted by
`VZMacMachineIdentifier(dataRepresentation:)` on the current host.

`VPhoneVirtualMachineManifest.load` rejects the missing marker before decoding
any other field. The current required hardware/storage fields match the legacy
manifest; the additional runtime preferences are optional. In a scratch folder,
a copy of this exact manifest with only `schemaVersion: 2` added is accepted
and listed by the current CLI. The original manifest and identity bytes were
checked unchanged. The scratch folder contains no disk and was never launched:
this verifies manifest compatibility, not guest boot or corporate authentication.

Evidence: `/private/tmp/vphone-legacy-schema-probe.OIJITg/` contains the probe,
converted manifest, CLI output and rejection of the unchanged copy.

Launchpad obtains its machine list from `vphone-cli vm list --json
--library-root`; it has no separate old-disk format restriction. It can remember
an additional library, so moving the old directory is not necessary for listing.
Moving a directory also need not change its device identity: the manifest uses
relative filenames, and the runtime derives ECID/UDID from the saved
`machineIdentifier`. Old and new hardware models retain PV=3, board 0x90 and
CPID 0xFE01. The new runtime opens existing NVRAM rather than recreating it.

The upstream refusal is an explicit support boundary. The inspected launch code
does not establish that restoring or generating another identity is technically
required. The earlier local recommendation to recreate the authenticated VM is
withdrawn.

## Remaining compatibility work

- The existing guest daemon uses length-prefixed JSON on VSOCK 1337. The new
  client uses HTTP/WebSocket on 1339. Starting the new runtime against the old
  daemon will not provide guest health, file/app tools or other RPC features.
- `vm launch` stages the new `.vphoned.signed` into the machine directory, and
  the new control client updates a compatible guest daemon automatically.
  Import must make agent migration explicit and preserve the old environment
  until a copy has been tested.
- The local old runtime omits VT/ANE/scaler accelerators to avoid the existing
  old-kernel paravirt failure. The new runtime enables them. An imported old VM
  must retain its working hardware settings rather than assume the disk has
  received the new kernel patches.
- The old manifest has an empty MAC, and software keyboard was a command-line
  flag. Import must record the required preferences and must not regenerate
  the machine identifier. If the saved identifier cannot be read, fail instead
  of silently making a new device.

## Import plan

1. Preserve the complete stopped VM and old launcher. Use an APFS copy-on-write
   copy to test compatibility; retain exactly the original device identity.
   Never run the original and that same-identity copy simultaneously.
2. Add an explicit legacy import/conversion path to the migration branch. Keep
   the disk, NVRAM, SEP, ROMs, identity and working legacy settings. Do not run
   `vm create`, restore, `--new-identity`, or guest-environment updates on the
   authenticated original as an import shortcut.
3. Resolve guest protocol and accelerator compatibility on the copy. Verify
   boot, preserved ECID/UDID, installed apps/data and the existing VPN
   authentication. A matching VM identifier alone does not prove that an
   external company service will keep accepting the device.
4. Only after acceptance, register or relocate the preserved VM into Launchpad's
   library. Retain a rollback to the old launcher. Directory relocation does
   not require a firmware restore.

## Installed workstation state

Launchpad 2.9.2 is installed at `/Applications/vphone-launchpad.app`, verified
against the release SHA-256 and accepted as a Notarized Developer ID app.
It is running. The user completed Host Setup and installed helper 16. Its
signature matches the notarized Launchpad's developer; CLI status reports
`hostReady: true`, `canInstallBundles: true` and `helper: ready (16)`. The user installed Core 2.9.3-local.e14eecc8; no machines are registered yet. No new VM was created, and no old guest file, identity,
manifest or disk was modified during this investigation.

## Implemented directory compatibility (2026-10-13)

`vm import-legacy <directory> --name <name>` clones only Disk/NVRAM/SEP/ROM
state with APFS CoW. It retains the original machineIdentifier byte-for-byte,
backs up the original manifest inside the copy, refuses invalid identifiers,
missing or symlinked storage, a busy original, and an existing destination. It
publishes the copy atomically. The source is never rewritten. A receipt allows
both CLI and VM runtime to refuse launch while that same-identity source is busy.

The imported schema-2 manifest records `legacyGuestEnvironment: true`,
`paravirtualAcceleratorsEnabled: false`, and the selected keyboard preference.
Normal manifest edits preserve these flags. This opt-in applies only to imported
legacy guests; current upstream guests keep the upstream behavior. Missing
imported device state fails at launch rather than generating replacement storage.

The host translates supported v2 RPC methods into the old framed-JSON protocol
on VSOCK 1337. One persistent serialized stream carries complete JSON/binary
exchanges. Length limits, a transaction deadline and a VSOCK-connect deadline
bound failures. Hello omits bin_hash, .vphoned.signed is not staged, and the
new guest/environment updater is not offered by the adapter. Unsupported newer
operations fail explicitly. HTTP API export is refused for a legacy guest.
The existing apps, clipboard, files, HID/touch, location, settings and shake
operations are supported without replacing the guest daemon.

`--socks5-host-port 1080` optionally forwards loopback TCP to the old guest's
existing direct SOCKS5 service, learning its stable alias from the legacy hello.
It retains NAT and guest routes. UDP clients should use the direct guest address,
as before. No tunnel is needed for Mac -> guest Feilian VPN traffic.

Targeted tests: 20 tests in LegacyImportTests, LegacyGuestSessionTests and
ManifestTests passed. They cover cloned state/identity, source preservation,
missing/invalid state refusal, destination/path refusal, same-identity activity
checks, persistent concurrent JSON/binary framing, uploads, guest refusals and
silent-peer timeouts. The complete signed VPhone bundle builds. Actual boot and
corporate authentication acceptance remain separate gates.

## Actual boot and user acceptance (2026-10-13)

The APFS copy booted twice with the installed compatibility Core
`2.9.3-local.0b0ec0e1` (source commit `633111c7`). The original config/NVRAM/SEP/ROM
SHA-256 fingerprints remained unchanged, and the copy reported the exact same
ECID/UDID. Its guest reports iOS 26.1.0 on macOS 26.3.1. Real legacy ping and
apps.list succeeded; the installed Feilian app was still present and running.

The tested copy was moved, while stopped, into `~/.vphone/machines/DefaultVM`,
bound to that Core, then started through the notarized Launchpad with a visible
VM window. Launchpad observed vphoned ready after 23 seconds. Original `vm/`
remains stopped and untouched. NAT and the old guest's direct SOCKS5 alias are
retained; host TCP 1080 forwards to guest 1080.

An earlier test host port 11080 was occupied by an unrelated Java process, so
its probe was not evidence about the VM. A direct guest SOCKS probe then reset.
The user explicitly took ownership of Feilian and Surge rules, and subsequently
reported everything normal. Corporate authentication/network acceptance is thus
user-reported, not an automated HTTPS/UDP proof. No assistant operation enabled
Feilian or modified Surge. New-firmware shake, all UI functions and prolonged
stability remain unverified individually; do not restart the user's active VM
or update its guest environment to expand those checks.
