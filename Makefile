# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
CPU         ?= 8          # CPU cores (only used during vm_new)
MEMORY      ?= 8192       # Memory in MB (only used during vm_new)
DISK_SIZE   ?= 64         # Disk size in GB (only used during vm_new)
RESTORE_UDID ?=           # UDID for restore operations
RESTORE_ECID ?=           # ECID for restore operations
RAMDISK_ECID ?=           # ECID for ramdisk transport operations

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
ENTITLEMENTS := sources/vphone.entitlements
VM_DIR_ABS  := $(abspath $(VM_DIR))
TOOLS_PREFIX := .tools

SWIFT_SOURCES := $(shell find sources -name '*.swift')

# ─── Environment — prefer project-local binaries ────────────────
export PATH := $(CURDIR)/$(TOOLS_PREFIX)/bin:$(CURDIR)/.build/release:$(PATH)

# ─── Default ──────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "vphone-cli — Virtual iPhone boot tool"
	@echo ""
	@echo "LazyCat (AIO):"
	@echo "  make setup_machine                   Full setup through First Boot"
	@echo "    Options: JB=1                      Jailbreak firmware/CFW path"
	@echo "             DEV=1                     Dev firmware/CFW path (dev TXM + cfw_install_dev)"
	@echo "             SKIP_PROJECT_SETUP=1      Skip setup_tools/build"
	@echo "             NONE_INTERACTIVE=1        Auto-continue prompts + boot analysis"
	@echo "             SUDO_PASSWORD=...         Preload sudo credential for setup flow"
	@echo ""
	@echo "Setup (one-time):"
	@echo "  make setup_tools             Install required host tools (vendored ldid, git-lfs, inject)"
	@echo ""
	@echo "Build:"
	@echo "  make build                   Build + sign vphone-cli"
	@echo "  make vphoned                 Cross-compile + sign vphoned for iOS"
	@echo "  make clean                   Remove all build artifacts (keeps IPSWs)"
	@echo ""
	@echo "VM management:"
	@echo "  make vm_new                  Create VM directory with manifest (config.plist)"
	@echo "    Options: VM_DIR=vm         VM directory name"
	@echo "             CPU=8             CPU cores (stored in manifest)"
	@echo "             MEMORY=8192       Memory in MB (stored in manifest)"
	@echo "             DISK_SIZE=64      Disk size in GB (stored in manifest)"
	@echo "  make amfidont_allow_vphone   Start amfidont for the signed vphone-cli binary"
	@echo "  make boot_host_preflight     Diagnose whether host can launch signed PV=3 binary"
	@echo "  make boot                    Boot VM (reads from config.plist)"
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
	@echo "  make fw_patch_dev            Patch boot chain with Swift pipeline (dev mode TXM patches)"
	@echo "  make fw_patch_jb             Patch boot chain with Swift pipeline (dev + JB extensions)"
	@echo ""
	@echo "Restore:"
	@echo "  make restore_get_shsh        Request restore personalization data"
	@echo "  make restore                 Restore firmware to the connected device"
	@echo ""
	@echo "Ramdisk:"
	@echo "  make ramdisk_build           Build signed SSH ramdisk"
	@echo "  make ramdisk_send            Send ramdisk to device"
	@echo ""
	@echo "CFW:"
	@echo "  make cfw_install             Install CFW mods via SSH"
	@echo "  make cfw_install_dev         Install CFW mods via SSH (dev mode)"
	@echo "  make cfw_install_jb          Install CFW + JB extensions (jetsam/procursus/basebin)"
	@echo ""
	@echo "Variables: VM_DIR=$(VM_DIR) CPU=$(CPU) MEMORY=$(MEMORY) DISK_SIZE=$(DISK_SIZE)"

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_machine setup_tools

setup_machine:
	@if [ "$(filter 1 true yes YES TRUE,$(JB))" != "" ] && [ "$(filter 1 true yes YES TRUE,$(DEV))" != "" ]; then \
		echo "Error: JB=1 and DEV=1 are mutually exclusive"; \
		exit 1; \
	fi
	VM_DIR="$(VM_DIR)" \
	JB="$(JB)" \
	DEV="$(DEV)" \
	SKIP_PROJECT_SETUP="$(SKIP_PROJECT_SETUP)" \
	NONE_INTERACTIVE="$(NONE_INTERACTIVE)" \
	SUDO_PASSWORD="$(SUDO_PASSWORD)" \
	"$(CURDIR)/$(PATCHER_BINARY)" setup-machine --project-root "$(CURDIR)"

setup_tools: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" setup-tools --project-root "$(CURDIR)"

# ═══════════════════════════════════════════════════════════════════
# Clean — remove all untracked/ignored files (preserves IPSWs only)
# ═══════════════════════════════════════════════════════════════════

.PHONY: clean
clean:
	@echo "=== Cleaning all untracked files (preserving IPSWs) ==="
	git clean -fdx -e '*.ipsw' -e '*_Restore*'

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

bundle: build setup_tools $(INFO_PLIST)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp -f $(BINARY) $(BUNDLE_BIN)
	@cp -f $(INFO_PLIST) $(BUNDLE)/Contents/Info.plist
	@cp -f sources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@cp -f $(SCRIPTS)/vphoned/signcert.p12 $(BUNDLE)/Contents/Resources/signcert.p12
	@cp -f $(CURDIR)/$(TOOLS_PREFIX)/bin/ldid $(BUNDLE)/Contents/MacOS/ldid
	@codesign --force --sign - $(BUNDLE)/Contents/MacOS/ldid
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUNDLE_BIN)
	@echo "  bundled → $(BUNDLE)"

# Cross-compile + sign vphoned daemon for iOS arm64 (requires vendored ldid)
.PHONY: vphoned
vphoned: setup_tools
	$(MAKE) -C $(SCRIPTS)/vphoned GIT_HASH=$(GIT_HASH)
	@echo "=== Signing vphoned ==="
	cp $(SCRIPTS)/vphoned/vphoned $(VM_DIR)/.vphoned.signed
	"$(CURDIR)/$(TOOLS_PREFIX)/bin/ldid" \
		-S$(SCRIPTS)/vphoned/entitlements.plist \
		-M "-K$(SCRIPTS)/vphoned/signcert.p12" \
		$(VM_DIR)/.vphoned.signed
	@echo "  signed → $(VM_DIR)/.vphoned.signed"

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: vm_new amfidont_allow_vphone boot_host_preflight boot boot_dfu boot_binary_check

vm_new: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" vm-create \
		--dir "$(VM_DIR_ABS)" \
		--disk-size "$(DISK_SIZE)" \
		--cpu "$(CPU)" \
		--memory "$(MEMORY)"

amfidont_allow_vphone: build patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" start-amfidont --project-root "$(CURDIR)"

boot_host_preflight: build patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" boot-host-preflight --project-root "$(CURDIR)"

boot_binary_check: $(BINARY) patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" boot-host-preflight --project-root "$(CURDIR)" --assert-bootable
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

boot: bundle vphoned boot_binary_check
	cd $(VM_DIR) && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist

boot_dfu: build boot_binary_check
	cd $(VM_DIR) && "$(CURDIR)/$(BINARY)" \
		--config ./config.plist \
		--dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch fw_patch_dev fw_patch_jb

fw_prepare: patcher_build
	cd $(VM_DIR) && \
		LIST_FIRMWARES="$(LIST_FIRMWARES)" \
		IPHONE_DEVICE="$(IPHONE_DEVICE)" \
		IPHONE_VERSION="$(IPHONE_VERSION)" \
		IPHONE_BUILD="$(IPHONE_BUILD)" \
		IPHONE_SOURCE="$(IPHONE_SOURCE)" \
		CLOUDOS_SOURCE="$(CLOUDOS_SOURCE)" \
		IPSW_DIR="$(IPSW_DIR)" \
		"$(CURDIR)/$(PATCHER_BINARY)" prepare-firmware --project-root "$(CURDIR)"

fw_patch: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant regular

fw_patch_dev: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant dev

fw_patch_jb: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant jb

# ═══════════════════════════════════════════════════════════════════
# Restore
# ═══════════════════════════════════════════════════════════════════

.PHONY: restore_get_shsh restore

restore_get_shsh:
	cd $(VM_DIR) && idevicerestore \
		$(if $(RESTORE_UDID),-u $(RESTORE_UDID),) \
		$(if $(RESTORE_ECID),-i $(RESTORE_ECID),) \
		-e -y ./iPhone*_Restore -t

restore:
	cd $(VM_DIR) && idevicerestore \
		$(if $(RESTORE_UDID),-u $(RESTORE_UDID),) \
		$(if $(RESTORE_ECID),-i $(RESTORE_ECID),) \
		-e -y ./iPhone*_Restore

# ═══════════════════════════════════════════════════════════════════
# Ramdisk
# ═══════════════════════════════════════════════════════════════════

.PHONY: ramdisk_build ramdisk_send

ramdisk_build: patcher_build
	cd $(VM_DIR) && RAMDISK_UDID="$(RAMDISK_UDID)" "$(CURDIR)/$(PATCHER_BINARY)" build-ramdisk .

ramdisk_send:
	cd $(VM_DIR) && \
		RAMDISK_ECID="$(RAMDISK_ECID)" \
		RAMDISK_UDID="$(RAMDISK_UDID)" \
		RESTORE_UDID="$(RESTORE_UDID)" \
		"$(CURDIR)/$(PATCHER_BINARY)" send-ramdisk

# ═══════════════════════════════════════════════════════════════════
# CFW
# ═══════════════════════════════════════════════════════════════════

.PHONY: cfw_install cfw_install_dev cfw_install_jb

cfw_install: patcher_build
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") "$(CURDIR)/$(PATCHER_BINARY)" cfw-install . --project-root "$(CURDIR)" --variant regular

cfw_install_dev: patcher_build
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") "$(CURDIR)/$(PATCHER_BINARY)" cfw-install . --project-root "$(CURDIR)" --variant dev

cfw_install_jb: patcher_build
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") "$(CURDIR)/$(PATCHER_BINARY)" cfw-install . --project-root "$(CURDIR)" --variant jb
