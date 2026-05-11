# vphone_shake — helper dylib loaded into user apps for UIEventSubtypeMotionShake

OUT       := vphone_shake.dylib
SRCS      := vphone_shake.m
SIGN_CERT := ../vphoned/signcert.p12
ENTITLE   := entitlements.plist

# Build for arm64. Targets are arm64e but arm64 dylibs load fine in arm64e
# processes (the PAC-aware caller side handles arm64 callees correctly).
ARCH      := arm64
SDK       := iphoneos

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRCS) $(ENTITLE)
	@echo "=== Building $(OUT) ==="
	xcrun -sdk $(SDK) clang -arch $(ARCH) -dynamiclib -fobjc-arc -Os \
		-framework Foundation -framework UIKit \
		-install_name @rpath/$(OUT) \
		-o $@ $(SRCS)
	@echo "=== Signing $(OUT) ==="
	ldid -S$(ENTITLE) -M -K$(SIGN_CERT) $@
	@echo "  built + signed: $(OUT)"

clean:
	rm -f $(OUT)
