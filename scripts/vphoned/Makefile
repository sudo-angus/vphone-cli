# vphoned — iOS guest daemon (cross-compiled for arm64 iphoneos)

SRCS         := $(wildcard *.m)
OUT          := vphoned
HELPER_DIR   := ../vphone_shake_helper
HELPER_DYLIB := $(HELPER_DIR)/vphone_shake.dylib
HELPER_HDR   := vphone_shake_dylib_data.h

# Passed from parent Makefile
GIT_HASH ?= unknown

.PHONY: all clean helper

all: $(OUT)

$(HELPER_DYLIB):
	$(MAKE) -C $(HELPER_DIR)

helper: $(HELPER_DYLIB)

# xxd -i embeds the signed helper bytes so vphoned can self-deploy at boot.
# It emits its own `vphone_shake_dylib_len` so we don't add one.
$(HELPER_HDR): $(HELPER_DYLIB)
	@echo "=== Embedding helper dylib ==="
	xxd -i -n vphone_shake_dylib < $(HELPER_DYLIB) > $@

$(OUT): $(SRCS) $(wildcard *.h) $(HELPER_HDR)
	@echo "=== Building vphoned (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-I. \
		-Ivendor/libarchive \
		-DVPHONED_BUILD_HASH='"$(GIT_HASH)"' \
		-o $@ $(SRCS) \
		-larchive \
		-lsqlite3 \
		-framework Foundation \
		-framework Security \
		-framework CoreServices
	@echo "  built OK"

clean:
	rm -f $(OUT) $(HELPER_HDR)
	$(MAKE) -C $(HELPER_DIR) clean
