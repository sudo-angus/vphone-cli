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
`hostReady: true`, `canInstallBundles: true` and `helper: ready (16)`. No Core
Bundle or machines are installed in the current default library. No new VM was created, and no old guest file, identity,
manifest or disk was modified during this investigation.
