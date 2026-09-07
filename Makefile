# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
# Absolute VM path: handles both relative (default `vm`) and absolute
# (e.g. external SSD) VM_DIR values. `abspath` leaves absolute paths intact
# and joins relative ones against CURDIR — use this for the VM directory arg.
VM_DIR_ABS  := $(abspath $(VM_DIR))
# CPU cores, memory (MB), disk size (GB) — used only during vm_new.
# NB: no inline comments on these `?=` lines — make would fold the trailing
# whitespace into the value (e.g. CPU="8   ") and break numeric consumers.
CPU         ?= 8
MEMORY      ?= 8192
DISK_SIZE   ?= 64
BACKUPS_DIR ?= vm.backups
NAME        ?=
BACKUP_INCLUDE_IPSW ?= 0
FORCE       ?= 0
RESTORE_UDID ?=           # UDID for restore operations
RESTORE_ECID ?=           # ECID for restore operations

# ─── Build info ──────────────────────────────────────────────────
GIT_HASH    := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_INFO  := sources/vphone-cli/VPhoneBuildInfo.swift

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS     := scripts
BINARY      := .build/release/vphone-cli
PATCHER_BINARY := .build/debug/vphone-cli
BUNDLE      := .build/vphone-cli.app
BUNDLE_BIN  := $(BUNDLE)/Contents/MacOS/vphone-cli
INFO_PLIST  := sources/Info.plist
MANAGER_BUNDLE     := .build/VPhone.app
MANAGER_BUNDLE_BIN := $(MANAGER_BUNDLE)/Contents/MacOS/vphone-cli
MANAGER_INFO_PLIST := sources/Info-Manager.plist
APP_INSTALL_PATH   ?= /Applications/VPhone.app
ENTITLEMENTS := sources/vphone.entitlements
VENV        := .venv
TOOLS_PREFIX := .tools
PMD3_BRIDGE := $(CURDIR)/$(SCRIPTS)/pymobiledevice3_bridge.py
PYTHON      := $(CURDIR)/$(VENV)/bin/python3

SWIFT_SOURCES := $(shell find sources -name '*.swift')

# ─── Environment — prefer project-local binaries ────────────────
export PATH := $(CURDIR)/$(TOOLS_PREFIX)/bin:$(CURDIR)/$(VENV)/bin:$(CURDIR)/.build/release:$(PATH)

# ─── Default ──────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "vphone-cli — Virtual iPhone boot tool"
	@echo ""
	@echo "LazyCat (AIO):"
	@echo "  make setup_machine                   Full setup through First Boot"
	@echo "    Options: JB=1                      Jailbreak firmware/CFW path"
	@echo "             DEV=1                     Dev firmware/CFW path (dev TXM + cfw_install_dev)"
	@echo "             EXP=1                     Experimental firmware/CFW path (JB + EXP-only patches:"
	@echo "                                       kernel hv_vmm rename, DSC byte-5 mangle, watchdogd surgical,"
	@echo "                                       DT identity properties, post-restore DT rewrite, opt-in build spoof)"
	@echo "             LESS=1                    Build, keeping iOS security mitigations enabled."
	@echo "             SKIP_PROJECT_SETUP=1      Skip setup_tools/build"
	@echo "             INTERACTIVE=1             Prompt at first-boot stages (default: non-interactive)"
	@echo "             SUDO_PASSWORD=...         Preload sudo credential for setup flow"
	@echo "             NO_BINPACK=1              Excludes the SSH, VNC, ... binaries from being installed (patchless-only, currently)"
	@echo "             NO_VPHONED=1              Excludes vphoned from being installed (patchless-only, currently)"
	@echo "             SPOOF_BUILD=<id>          (EXP only) Rewrite ProductBuildVersion in SystemVersion.plist to <id>"
	@echo "                                       e.g. SPOOF_BUILD=23F77 makes Settings -> About show that build."
	@echo "                                       Omitted/empty -> EXP-JB-7 skipped, build version stays at the IPSW value."
	@echo ""
	@echo "Setup (one-time):"
	@echo "  make setup_tools             Install all tools (brew, trustcache, insert_dylib, venv+pymobiledevice3)"
	@echo ""
	@echo "Build:"
	@echo "  make build                   Build + sign vphone-cli"
	@echo "  make manage                  Build + launch the VPhone manager GUI (manage/start/stop VMs)"
	@echo "  make install_app             One-shot: submodules + setup_tools + build + /Applications launcher"
	@echo "                               (the only command a fresh clone needs for the GUI entry)"
	@echo "    Options: APP_INSTALL_PATH=/Applications/VPhone.app   Install destination"
	@echo "  make uninstall_app           Remove the /Applications/VPhone.app symlink"
	@echo "  make vphoned                 Cross-compile + sign vphoned for iOS"
	@echo "  make clean                   Remove build/tooling artifacts only"
	@echo "    Options: CLEAN_VM=1        Also remove VM_DIR=$(VM_DIR) after confirmation"
	@echo "             CLEAN_IPSW=1      Also remove ipsws/ after confirmation"
	@echo ""
	@echo "VM management:"
	@echo "  make vm_new                  Create VM directory with manifest (config.plist)"
	@echo "    Options: VM_DIR=vm         VM directory name"
	@echo "             CPU=8             CPU cores (stored in manifest)"
	@echo "             MEMORY=8192       Memory in MB (stored in manifest)"
	@echo "             DISK_SIZE=64      Disk size in GB (stored in manifest)"
	@echo "  make vm_backup NAME=<name>   Save current VM as a named backup"
	@echo "  make vm_restore NAME=<name>  Restore a named backup into vm/"
	@echo "  make vm_switch NAME=<name>   Save current + restore target (one step)"
	@echo "  make vm_list                 List available backups"
	@echo "    Options: BACKUP_INCLUDE_IPSW=1  Include *_Restore* IPSW dirs in backup"
	@echo "             FORCE=1                Skip overwrite prompt on restore"
	@echo "  make amfidont_allow_vphone   Start amfidont for the signed vphone-cli binary"
	@echo "  make boot_host_preflight     Diagnose whether host can launch signed PV=3 binary"
	@echo "  make boot                    Boot VM (reads from config.plist)"
	@echo "    Options: EXTRA_ARGS=...    Pass vphone-cli boot args"
	@echo "             --usbmux-forward L:G  Native usbmux TCP forward; repeatable"
	@echo "                                      e.g. EXTRA_ARGS=\"--usbmux-forward 2222:22222 --usbmux-forward 5910:5910\""
	@echo "  make boot_less               Boot VM in vphoned patchless compatibility"
	@echo "    Options: NO_VPHONED=1              Excludes vphoned from being installed"
	@echo "  make boot_dfu                Boot VM in DFU mode (reads from config.plist)"
	@echo ""
	@echo "Firmware pipeline:"
	@echo "  make fw_prepare              Download IPSWs, extract, merge"
	@echo "    Options: LIST_FIRMWARES=1  List downloadable iPhone IPSWs for IPHONE_DEVICE and exit"
	@echo "             IPHONE_DEVICE=    Device identifier for firmware lookup (default: iPhone17,3)"
	@echo "             IPHONE_VERSION=   Resolve a downloadable iPhone version to an IPSW URL"
	@echo "             IPHONE_BUILD=     Resolve a downloadable iPhone build to an IPSW URL"
	@echo "             IPHONE_SOURCE=    URL or local path to iPhone IPSW"
	@echo "             CLOUDOS_SOURCE=   URL or local path to cloudOS IPSW"
	@echo "  make fw_patch                Patch boot chain with Swift pipeline (regular variant)"
	@echo "    Options: FORCE_EXC_GUARD=1        Force the EXC_GUARD Mach-port-guard disable patch even on bases"
	@echo "                                      that don't strictly need it to boot (e.g. a 3rd-party app's"
	@echo "                                      crash-reporting SDK trips a fatal GUARD_TYPE_MACH_PORT violation)"
	@echo "  make fw_patch_less           Patch boot chain with Swift pipeline (less patches)"
	@echo "    Options: NO_BINPACK=1              Excludes the SSH, VNC, ... binaries from being installed"
	@echo "             NO_VPHONED=1              Excludes vphoned from being installed"
	@echo "  make fw_patch_dev            Patch boot chain with Swift pipeline (dev mode TXM patches)"
	@echo "  make fw_patch_jb             Patch boot chain with Swift pipeline (dev + JB extensions)"
	@echo "    Options: FORCE_EXC_GUARD=1        (see fw_patch above)"
	@echo "             FRIDA=1                  Opt in to the Frida Stalker kernel relaxations"
	@echo "  make fw_patch_exp            Patch boot chain with Swift pipeline (JB + EXP experimental)"
	@echo "    Options: FORCE_EXC_GUARD=1        (see fw_patch above)"
	@echo "             FRIDA=1                  Opt in to the Frida Stalker kernel relaxations"
	@echo "  make fw_cache_list           List cached firmware in ipsws/ with per-firmware sizes"
	@echo ""
	@echo "Testing:"
	@echo "  make test_jb_patches         Run all JB kernel patches (incl. Sandbox) over every supported cloudOS kernel"
	@echo "    Options: QUICK=1           Only the local/newest kernel (fast dev loop)"
	@echo "  make test_fw_patches         Run the FULL patch-firmware pipeline (boot chain + base kernel + JB + EXP) over"
	@echo "                               each local cloudOS firmware; fails on any skipped sub-patch (broad drift gate)"
	@echo "    Options: QUICK=1           Only the newest local cloudOS firmware"
	@echo "             VARIANTS=\"exp\"     Limit to specific variants (default: jb exp)"
	@echo ""
	@echo "Restore:"
	@echo "  make restore_get_shsh        Dump SHSH response from Apple"
	@echo "  make restore                 Restore to device (pymobiledevice3 backend)"
	@echo "  make restore_offline         Restore offline — decrypts AEA images in place, uses cached .shsh blob"
	@echo ""
	@echo "CFW (host-mount install; VM must be off, re-execs sudo):"
	@echo "  make cfw_install             Install base CFW mods"
	@echo "  make cfw_install_dev         Install CFW mods (dev mode)"
	@echo "  make cfw_install_jb          Install CFW + JB extensions (jetsam/procursus/basebin)"
	@echo "  make cfw_install_exp         Install CFW + JB + EXP experimental (hv_vmm rename, post-restore DT, build spoof)"
	@echo "  make cfw_install_host        Select variant: VARIANT=regular|dev|jb|exp (default exp)  SPOOF_BUILD=<id> (exp)"
	@echo ""
	@echo "Variables: VM_DIR=$(VM_DIR) CPU=$(CPU) MEMORY=$(MEMORY) DISK_SIZE=$(DISK_SIZE)"

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_machine setup_tools

setup_machine:
	@if count=0; \
	  [ -n "$(filter 1 true yes YES TRUE,$(JB))" ] && count=$$((count+1)); \
	  [ -n "$(filter 1 true yes YES TRUE,$(DEV))" ] && count=$$((count+1)); \
	  [ -n "$(filter 1 true yes YES TRUE,$(EXP))" ] && count=$$((count+1)); \
	  [ -n "$(filter 1 true yes YES TRUE,$(LESS))" ] && count=$$((count+1)); \
	  [ $$count -gt 1 ]; then \
		echo "Error: JB=1, DEV=1, EXP=1, and LESS=1 are mutually exclusive"; \
		exit 1; \
	fi
	SUDO_PASSWORD="$(SUDO_PASSWORD)" \
	INTERACTIVE="$(INTERACTIVE)" \
	NO_BINPACK="$(NO_BINPACK)" \
	NO_VPHONED="$(NO_VPHONED)" \
	SPOOF_BUILD="$(SPOOF_BUILD)" \
	zsh $(SCRIPTS)/setup_machine.sh \
		$(if $(filter 1 true yes YES TRUE,$(JB)),--jb,) \
		$(if $(filter 1 true yes YES TRUE,$(DEV)),--dev,) \
		$(if $(filter 1 true yes YES TRUE,$(EXP)),--exp,) \
		$(if $(filter 1 true yes YES TRUE,$(LESS)),--less,) \
		$(if $(filter 1 true yes YES TRUE,$(SKIP_PROJECT_SETUP)),--skip-project-setup,)

setup_tools:
	VARIANT=$(VARIANT) zsh $(SCRIPTS)/setup_tools.sh

# ═══════════════════════════════════════════════════════════════════
# Clean — remove generated build/tooling files by default.
# Destructive VM/IPSW cleanup is opt-in and requires confirmation.
# ═══════════════════════════════════════════════════════════════════

.PHONY: clean
clean:
	@set -e; \
	echo "=== Cleaning build/tooling artifacts ==="; \
	echo "Removing: .build .swiftpm .vphoned.signed $(VENV) $(TOOLS_PREFIX)"; \
	if [ "$(CLEAN_VM)" = "1" ] || [ "$(CLEAN_IPSW)" = "1" ]; then \
		echo ""; \
		echo "WARNING: destructive clean requested."; \
		[ "$(CLEAN_VM)" = "1" ] && echo "  VM directory: $(VM_DIR)/"; \
		[ "$(CLEAN_IPSW)" = "1" ] && echo "  IPSW cache:   ipsws/"; \
		printf "Also remove destructive targets above? [y/N] "; \
		read answer; \
		case "$$answer" in y|Y|yes|YES) ;; *) \
			echo "[-] Destructive clean cancelled; no files removed."; \
			exit 0; \
		esac; \
	fi; \
	rm -rf .build .swiftpm .vphoned.signed "$(VENV)" "$(TOOLS_PREFIX)"; \
	if [ "$(CLEAN_VM)" = "1" ] || [ "$(CLEAN_IPSW)" = "1" ]; then \
		if [ "$(CLEAN_VM)" = "1" ]; then rm -rf "$(VM_DIR)"; fi; \
		if [ "$(CLEAN_IPSW)" = "1" ]; then rm -rf ipsws; fi; \
	fi

# ═══════════════════════════════════════════════════════════════════
# Build
# ═══════════════════════════════════════════════════════════════════

.PHONY: build patcher_build bundle

build: $(BINARY)

patcher_build: $(PATCHER_BINARY)

$(PATCHER_BINARY): $(SWIFT_SOURCES) Package.swift
	@echo "=== Building vphone-cli patcher ($(GIT_HASH)) ==="
	@echo '// Auto-generated — do not edit' > $(BUILD_INFO)
	@echo 'enum VPhoneBuildInfo { static let commitHash = "$(GIT_HASH)" }' >> $(BUILD_INFO)
	@set -o pipefail; swift build 2>&1 | tail -5

$(BINARY): $(SWIFT_SOURCES) Package.swift $(ENTITLEMENTS)
	@echo "=== Building vphone-cli ($(GIT_HASH)) ==="
	@echo '// Auto-generated — do not edit' > $(BUILD_INFO)
	@echo 'enum VPhoneBuildInfo { static let commitHash = "$(GIT_HASH)" }' >> $(BUILD_INFO)
	@set -o pipefail; swift build -c release 2>&1 | tail -5
	@echo ""
	@echo "=== Signing with entitlements ==="
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $@
	@echo "  signed OK"

bundle: build $(INFO_PLIST)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp -f $(BINARY) $(BUNDLE_BIN)
	@cp -f $(INFO_PLIST) $(BUNDLE)/Contents/Info.plist
	@cp -f sources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@cp -f $(SCRIPTS)/vphoned/signcert.p12 $(BUNDLE)/Contents/Resources/signcert.p12
	@# VPhoneResources resolves a bundled binary's assets under Resources/scripts/…
	@# (build.sh mirrors the whole tree); mirror the one asset the boot path
	@# reads at runtime so IPA install keeps its signing cert with a make-built app.
	@mkdir -p $(BUNDLE)/Contents/Resources/scripts/vphoned
	@cp -f $(SCRIPTS)/vphoned/signcert.p12 $(BUNDLE)/Contents/Resources/scripts/vphoned/signcert.p12
	@cp -f $$(command -v ldid) $(BUNDLE)/Contents/MacOS/ldid
	@codesign --force --sign - $(BUNDLE)/Contents/MacOS/ldid
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUNDLE_BIN)
	@echo "  bundled → $(BUNDLE)"

# ── VM manager (GUI) ─────────────────────────────────────────────
# VPhone.app is the always-on manager. It is signed WITHOUT the private
# virtualization entitlements so AMFI always lets it launch (so it can start
# amfidont); it supervises the entitled boot binary from `bundle`.
.PHONY: manager_app manage
manager_app: bundle vphoned $(MANAGER_INFO_PLIST)
	@mkdir -p $(MANAGER_BUNDLE)/Contents/MacOS $(MANAGER_BUNDLE)/Contents/Resources
	@cp -f $(BINARY) $(MANAGER_BUNDLE_BIN)
	@cp -f $(MANAGER_INFO_PLIST) $(MANAGER_BUNDLE)/Contents/Info.plist
	@cp -f sources/AppIcon-Manager.icns $(MANAGER_BUNDLE)/Contents/Resources/AppIcon.icns
	@codesign --force --sign - $(MANAGER_BUNDLE_BIN)
	@echo "  bundled → $(MANAGER_BUNDLE)"

# Build + launch the manager GUI.
manage: manager_app
	"$(CURDIR)/$(MANAGER_BUNDLE_BIN)" manage

# ── /Applications launcher ───────────────────────────────────────
# `make install_app` is the one-shot, user-facing entry point. On a fresh clone
# this is the ONLY command a user has to run; it is idempotent end to end:
#   1. init the vendor SPM submodules so `swift build` can compile,
#   2. run setup_tools once if host tools are missing (ldid + venv),
#   3. build + ad-hoc-sign the manager/boot bundles,
#   4. copy the bundle to /Applications/VPhone.app, record this clone's path
#      inside it, and index it — so it appears in Spotlight/Launchpad/Dock.
# It installs a real *copy*, not a symlink: Spotlight and Launchpad skip
# symlinked bundles (they never show up in search), which a symlink can't fix.
# The copied manager finds this clone via the embedded repo-root resource
# (VPhoneVMRegistry.findRepoRoot) and always spawns the entitled boot binary from
# the live build, so day-to-day `make build` needs no re-install; re-run
# install_app only to refresh the manager binary itself. No sudo (/Applications
# is admin-group-writable) and no Apple Developer account (ad-hoc signing on an
# AMFI-disabled host). Finally it offers to launch the app.
.PHONY: install_app uninstall_app
install_app:
	@command -v swift >/dev/null 2>&1 || { \
		echo "Error: 'swift' not found — install Xcode Command Line Tools first:"; \
		echo "       xcode-select --install"; \
		exit 1; \
	}
	@if [ ! -f vendor/Dynamic/Package.swift ]; then \
		echo "=== Initializing vendor submodules (one-time) ==="; \
		git submodule update --init --recursive \
			vendor/Dynamic vendor/swift-argument-parser vendor/MachOKit \
			vendor/libcapstone-spm vendor/libimg4-spm; \
	fi
	@if ! command -v ldid >/dev/null 2>&1 || [ ! -d "$(VENV)" ]; then \
		command -v brew >/dev/null 2>&1 || { \
			echo "Error: Homebrew is required for first-time setup. Install it from https://brew.sh and re-run."; \
			exit 1; \
		}; \
		echo "=== Host tools missing — running setup_tools (one-time) ==="; \
		$(MAKE) setup_tools; \
	fi
	@$(MAKE) manager_app
	@if [ -e "$(APP_INSTALL_PATH)" ] && [ ! -L "$(APP_INSTALL_PATH)" ]; then \
		bid=$$(defaults read "$(APP_INSTALL_PATH)/Contents/Info" CFBundleIdentifier 2>/dev/null || echo ""); \
		if [ "$$bid" != "com.vphone.manager" ]; then \
			echo "Error: $(APP_INSTALL_PATH) exists and isn't VPhone (id: $$bid)."; \
			echo "       Remove it manually, then re-run: make install_app"; \
			exit 1; \
		fi; \
	fi
	@rm -rf "$(APP_INSTALL_PATH)"
	@cp -R "$(MANAGER_BUNDLE)" "$(APP_INSTALL_PATH)"
	@printf '%s' "$(CURDIR)" > "$(APP_INSTALL_PATH)/Contents/Resources/repo-root"
	@codesign --force --sign - "$(APP_INSTALL_PATH)/Contents/MacOS/vphone-cli" >/dev/null 2>&1 || true
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$(APP_INSTALL_PATH)" >/dev/null 2>&1 || true
	@/usr/bin/mdimport "$(APP_INSTALL_PATH)" >/dev/null 2>&1 || true
	@echo ""
	@echo "  installed → $(APP_INSTALL_PATH)"
	@echo "  source clone: $(CURDIR)"
	@if [ -t 0 ]; then \
		first=$$(defaults read -g AppleLanguages 2>/dev/null | tr -d ' ",()' | sed '/^$$/d' | head -1); \
		case "$$first" in zh*) cn=1;; *) cn=0;; esac; \
		if [ "$$cn" = 1 ]; then printf "\n现在启动 VPhone 吗？[Y/n] "; else printf "\nLaunch VPhone now? [Y/n] "; fi; \
		read ans; \
		case "$$ans" in \
			n|N|no|NO|No) \
				if [ "$$cn" = 1 ]; then echo "已安装。随时可在 Spotlight / Launchpad 搜索 “VPhone” 启动。"; \
				else echo "Installed. Launch “VPhone” any time from Spotlight / Launchpad."; fi ;; \
			*) \
				open -a VPhone || open "$(APP_INSTALL_PATH)"; \
				echo ""; \
				echo "════════════════════════════════════════════════════════════"; \
				if [ "$$cn" = 1 ]; then \
					echo "  ⚠  下一步：点击 VPhone 窗口顶部高亮的「Authorize admin」"; \
					echo "      授权后（安装一次性 sudoers 规则）才能启动 VM。"; \
				else \
					echo "  ⚠  Next: click the highlighted “Authorize admin” banner"; \
					echo "      at the top of the VPhone window before starting a VM."; \
				fi; \
				echo "════════════════════════════════════════════════════════════"; ;; \
		esac; \
	else \
		echo "  Launch “VPhone” from Spotlight / Launchpad, or: open -a VPhone"; \
	fi

uninstall_app:
	@if [ -L "$(APP_INSTALL_PATH)" ]; then \
		rm -f "$(APP_INSTALL_PATH)"; \
		echo "  removed $(APP_INSTALL_PATH) (symlink)"; \
	elif [ -d "$(APP_INSTALL_PATH)" ]; then \
		bid=$$(defaults read "$(APP_INSTALL_PATH)/Contents/Info" CFBundleIdentifier 2>/dev/null || echo ""); \
		if [ "$$bid" = "com.vphone.manager" ]; then \
			rm -rf "$(APP_INSTALL_PATH)"; \
			echo "  removed $(APP_INSTALL_PATH)"; \
		else \
			echo "  $(APP_INSTALL_PATH) isn't VPhone (id: $$bid) — left untouched"; \
		fi; \
	else \
		echo "  $(APP_INSTALL_PATH) not present — nothing to do"; \
	fi

# Cross-compile + sign vphoned daemon for iOS arm64 (requires ldid)
.PHONY: vphoned
# The signed daemon is staged at .build/vphoned.signed — where VPhoneResources'
# dev layout (and the manager, before every boot) looks for it — and mirrored
# into $(VM_DIR) for a plain `make boot` when that directory exists.
vphoned:
	@command -v ldid >/dev/null 2>&1 \
		|| (echo "Error: ldid not found. Run: brew install ldid-procursus" && exit 1)
	$(MAKE) -C $(SCRIPTS)/vphoned GIT_HASH=$(GIT_HASH)
	@echo "=== Signing vphoned ==="
	@mkdir -p .build
	cp $(SCRIPTS)/vphoned/vphoned .build/vphoned.signed
	ldid \
		-S$(SCRIPTS)/vphoned/entitlements.plist \
		-M "-K$(SCRIPTS)/vphoned/signcert.p12" \
		.build/vphoned.signed
	@echo "  signed → .build/vphoned.signed"
	@if [ -d "$(VM_DIR)" ]; then \
		cp -f .build/vphoned.signed "$(VM_DIR)/.vphoned.signed"; \
		echo "  staged → $(VM_DIR)/.vphoned.signed"; \
	fi

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: vm_new vm_backup vm_restore vm_switch vm_list amfidont_allow_vphone boot_host_preflight boot boot_less boot_dfu boot_binary_check

vm_new:
	CPU="$(CPU)" MEMORY="$(MEMORY)" \
	zsh $(SCRIPTS)/vm_create.sh --dir "$(VM_DIR)" --disk-size $(DISK_SIZE)

vm_backup:
	VM_DIR="$(VM_DIR)" BACKUPS_DIR="$(BACKUPS_DIR)" NAME="$(NAME)" BACKUP_INCLUDE_IPSW="$(BACKUP_INCLUDE_IPSW)" \
	zsh $(SCRIPTS)/vm_backup.sh

vm_restore:
	VM_DIR="$(VM_DIR)" BACKUPS_DIR="$(BACKUPS_DIR)" NAME="$(NAME)" FORCE="$(FORCE)" \
	zsh $(SCRIPTS)/vm_restore.sh

vm_switch:
	VM_DIR="$(VM_DIR)" BACKUPS_DIR="$(BACKUPS_DIR)" NAME="$(NAME)" BACKUP_INCLUDE_IPSW="$(BACKUP_INCLUDE_IPSW)" \
	zsh $(SCRIPTS)/vm_switch.sh

vm_list:
	@if [ -d "$(BACKUPS_DIR)" ]; then \
		current=""; \
		[ -f "$(VM_DIR)/.vm_name" ] && current="$$(cat "$(VM_DIR)/.vm_name")"; \
		found=0; \
		for d in "$(BACKUPS_DIR)"/*/; do \
			[ -f "$${d}config.plist" ] || continue; \
			name="$$(basename "$$d")"; \
			size="$$(du -sh "$$d" 2>/dev/null | cut -f1)"; \
			if [ "$$name" = "$$current" ]; then \
				echo "  * $$name ($$size) [active]"; \
			else \
				echo "    $$name ($$size)"; \
			fi; \
			found=1; \
		done; \
		if [ "$$found" = "0" ]; then echo "  (no backups yet — run: make vm_backup NAME=<name>)"; fi; \
	else \
		echo "  (no backups yet — run: make vm_backup NAME=<name>)"; \
	fi

amfidont_allow_vphone: bundle
	zsh $(SCRIPTS)/start_amfidont_for_vphone.sh

boot_host_preflight: build
	zsh $(SCRIPTS)/boot_host_preflight.sh

define BOOT_BINARY_CHECK
	@zsh $(SCRIPTS)/boot_host_preflight.sh $(1)
	@tmp_log="$$(mktemp -t vphone-boot-preflight.XXXXXX)"; \
	set +e; \
	"$(CURDIR)/$(BINARY)" --help >"$$tmp_log" 2>&1; \
	rc=$$?; \
	set -e; \
	if [ $$rc -ne 0 ]; then \
		echo "Error: signed vphone-cli failed to launch (exit $$rc)." >&2; \
		echo "Check private virtualization entitlement support and ensure SIP/AMFI are disabled on the host." >&2; \
		echo "Repo workaround: start the AMFI bypass helper with 'make amfidont_allow_vphone' and retry." >&2; \
		if [ -s "$$tmp_log" ]; then \
			echo "--- vphone-cli preflight log ---" >&2; \
			tail -n 40 "$$tmp_log" >&2; \
		fi; \
		rm -f "$$tmp_log"; \
		exit $$rc; \
	fi; \
	rm -f "$$tmp_log"
endef

boot_binary_check_less: $(BINARY)
	$(call BOOT_BINARY_CHECK,--assert-bootable --less)

boot_binary_check: $(BINARY)
	$(call BOOT_BINARY_CHECK,--assert-bootable)

boot: bundle vphoned boot_binary_check
	cd "$(VM_DIR)" && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist $(EXTRA_ARGS)

boot_less: bundle boot_binary_check_less
	cd "$(VM_DIR)" && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist \
		--variant less \
		$(if $(filter 1 true yes YES TRUE,$(NO_VPHONED)),--no-vphoned,)

boot_dfu: build boot_binary_check
	cd "$(VM_DIR)" && "$(CURDIR)/$(BINARY)" \
		--config ./config.plist \
		--dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch fw_patch_less fw_patch_dev fw_patch_jb

fw_prepare:
	cd "$(VM_DIR)" && bash "$(CURDIR)/$(SCRIPTS)/fw_prepare.sh"

fw_patch: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant regular \
	$(if $(filter 1 true yes YES TRUE,$(FORCE_EXC_GUARD)),--force-exc-guard,)

UID := $(shell id -u)
ifeq ($(UID),0)
fw_patch_less: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" \
	--variant less \
	$(if $(filter 1 true yes YES TRUE,$(NO_BINPACK)),--no-binpack,)
	$(if $(filter 1 true yes YES TRUE,$(NO_VPHONED)),--no-vphoned,)
else
fw_patch_less:
	@echo "fw_patch_less must be run via sudo"
	@exit 1
endif

fw_patch_dev: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant dev

fw_patch_jb: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant jb \
	$(if $(filter 1 true yes YES TRUE,$(FORCE_EXC_GUARD)),--force-exc-guard,) \
	$(if $(filter 1 true yes YES TRUE,$(FRIDA)),--frida,)

fw_patch_exp: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant exp \
	$(if $(filter 1 true yes YES TRUE,$(FORCE_EXC_GUARD)),--force-exc-guard,) \
	$(if $(filter 1 true yes YES TRUE,$(FRIDA)),--frida,)

.PHONY: test_jb_patches

# Run the full JB kernel patch layer (every hook, incl. all Sandbox ops hooks)
# over EVERY cloudOS kernel the README supports — correctness + backward-compat.
# Downloads each version's kernelcache on demand (cached under /tmp/vphone_kjb_versions).
#   Options: QUICK=1   Only the local/newest kernel (fast dev loop)
test_jb_patches: patcher_build
	zsh "$(CURDIR)/tests/test_jb_kernel_patches.sh" --no-build \
		$(if $(filter 1 true yes YES TRUE,$(QUICK)),--quick,)

.PHONY: test_fw_patches

# Run the FULL patch-firmware pipeline (boot chain + base kernel + JB + EXP, every
# component) over each locally-prepared cloudOS firmware, for the jb and exp
# variants, and fail if ANY component skips a sub-patch (a `[-]` line). This is the
# broad gate that catches drift outside the JB kernel layer (iBSS/iBEC/LLB, base
# KernelPatcher, TXM, DeviceTree) — which test_jb_patches structurally cannot see.
#   Options: QUICK=1            Only the newest local cloudOS firmware
#            VARIANTS="exp"     Limit to specific variants (default: jb exp)
test_fw_patches: patcher_build
	zsh "$(CURDIR)/tests/test_firmware_patches.sh" --no-build \
		$(if $(filter 1 true yes YES TRUE,$(QUICK)),--quick,)

# Read-only inventory of the firmware cache (ipsws/), with per-firmware sizes.
.PHONY: fw_cache_list
fw_cache_list:
	@zsh "$(CURDIR)/$(SCRIPTS)/fw_cache_list.sh"

# ═══════════════════════════════════════════════════════════════════
# Restore
# ═══════════════════════════════════════════════════════════════════

.PHONY: restore_get_shsh restore restore_offline

# Resolve ECID from RESTORE_ECID or vm/udid-prediction.txt (written by boot_dfu).
define _resolve_ecid
	if [ -n "$(RESTORE_ECID)" ]; then \
		ECID="$(RESTORE_ECID)"; \
	elif [ -f "$(VM_DIR_ABS)/udid-prediction.txt" ]; then \
		ECID=$$(grep '^ECID=' "$(VM_DIR_ABS)/udid-prediction.txt" | head -1 | cut -d= -f2); \
	fi; \
	if [ -z "$$ECID" ]; then \
		echo "[-] Cannot resolve ECID — set RESTORE_ECID or run 'make boot_dfu' first"; \
		exit 1; \
	fi
endef

restore_get_shsh:
	@$(call _resolve_ecid); \
	cd "$(VM_DIR)" && "$(PYTHON)" "$(PMD3_BRIDGE)" restore-get-shsh \
		--vm-dir . \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

restore:
	@$(call _resolve_ecid); \
	cd "$(VM_DIR)" && "$(PYTHON)" "$(PMD3_BRIDGE)" restore-update \
		--vm-dir . \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

restore_offline:
	@$(call _resolve_ecid); \
	SHSH=$$(ls "$(VM_DIR_ABS)/"*.shsh 2>/dev/null | head -1); \
	if [ -z "$$SHSH" ]; then \
		echo "[-] No .shsh file in $(VM_DIR)/ — run 'make restore_get_shsh' first"; \
		exit 1; \
	fi; \
	RESTORE_SRC=$$(echo "$(VM_DIR_ABS)/iPhone"*_Restore); \
	if [ ! -d "$$RESTORE_SRC" ]; then \
		echo "[-] No iPhone*_Restore directory in $(VM_DIR)/"; \
		exit 1; \
	fi; \
	echo "[+] Decrypting AEA images in place..."; \
	for aea in "$$RESTORE_SRC"/*.dmg.aea; do \
		[ -f "$$aea" ] || continue; \
		[ "$$(xxd -l 4 -p "$$aea")" = "41454131" ] || continue; \
		base=$$(basename "$$aea"); \
		if ! ipsw fw aea -o "$$RESTORE_SRC" "$$aea"; then \
			echo "[-] ipsw fw aea failed for $$base — aborting"; \
			exit 1; \
		fi; \
		if ! mv -f "$$RESTORE_SRC/$${base%.aea}" "$$aea"; then \
			echo "[-] mv failed for $$base — aborting (decrypted file missing?)"; \
			exit 1; \
		fi; \
		if [ "$$(xxd -l 4 -p "$$aea")" = "41454131" ]; then \
			echo "[-] $$base still AEA1-encrypted after decrypt — aborting"; \
			exit 1; \
		fi; \
	done; \
	echo "[+] Restoring offline with SHSH: $$(basename $$SHSH)"; \
	cd "$(VM_DIR)" && "$(PYTHON)" "$(PMD3_BRIDGE)" restore-update \
		--vm-dir . \
		--tss "$$SHSH" \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

# ═══════════════════════════════════════════════════════════════════
# CFW
# ═══════════════════════════════════════════════════════════════════

.PHONY: cfw_install cfw_install_dev cfw_install_jb cfw_install_exp cfw_install_host

cfw_install:
	$(MAKE) cfw_install_host VARIANT=regular

cfw_install_dev:
	$(MAKE) cfw_install_host VARIANT=dev

cfw_install_jb:
	$(MAKE) cfw_install_host VARIANT=jb FRIDA="$(FRIDA)"

cfw_install_exp:
	$(MAKE) cfw_install_host VARIANT=exp SPOOF_BUILD="$(SPOOF_BUILD)" FRIDA="$(FRIDA)"

# CFW install: place files via host mount + flip the boot snapshot offline.
# VM must be off; re-execs under sudo.
#   Options: VARIANT=regular|dev|jb|exp (default exp)  SPOOF_BUILD=<id> (exp)
cfw_install_host:
	$(if $(SPOOF_BUILD),SPOOF_BUILD="$(SPOOF_BUILD)") $(if $(filter 1 true yes YES TRUE,$(FRIDA)),VPHONE_FRIDA=1) zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_host.sh" --variant $(if $(VARIANT),$(VARIANT),exp) "$(VM_DIR_ABS)"
