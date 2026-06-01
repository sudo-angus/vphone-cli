# vphoned — iOS guest daemon (cross-compiled for arm64 iphoneos)

SRCS         := $(wildcard *.m)
OUT          := vphoned

# Passed from parent Makefile
GIT_HASH ?= unknown

.PHONY: all clean

all: $(OUT)

# Note: the shake gesture is now pure injected shellcode (see vphoned_motion.m),
# so vphoned no longer embeds vphone_shake_helper.dylib. The helper sources are
# kept under ../vphone_shake_helper for the Jailbreak-variant dlopen approach.

$(OUT): $(SRCS) $(wildcard *.h)
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
	rm -f $(OUT) vphone_shake_dylib_data.h
