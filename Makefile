# Hush — build & install a silent virtual audio input driver for macOS.

BUNDLE     := Hush.driver
EXEC       := Hush
SRC        := src/Hush.swift
HAL_DIR    := /Library/Audio/Plug-Ins/HAL
CODESIGN_IDENTITY ?= -

DEPLOY     := 11.0
ARCHS      := arm64 x86_64
SWIFTFLAGS := -O -parse-as-library -emit-library -Xlinker -bundle \
              -framework CoreAudio -framework CoreFoundation
BUILD      := build

# --- Distribution (Developer ID signing + notarization) ---------------------
# Override on the command line as needed, e.g.
#   make dist DEV_ID_INSTALLER="Developer ID Installer: Tim Schmolka (GCWU97Q534)"
VERSION          := 1.0.0
PKG_ID           := com.timschmolka.hush
PKG              := Hush-$(VERSION).pkg
DEV_ID_APP       ?= Developer ID Application: Tim Schmolka (GCWU97Q534)
DEV_ID_INSTALLER ?= Developer ID Installer: Tim Schmolka (GCWU97Q534)
# Name of a notarytool keychain profile. Reuses the existing account-wide
# credential (create with: xcrun notarytool store-credentials notarytool-profile
#   --apple-id <id> --team-id GCWU97Q534 --password <app-specific-pw>).
NOTARY_PROFILE   ?= notarytool-profile
# How notarytool authenticates. Locally this uses the keychain profile; CI
# overrides it with App Store Connect API-key args, e.g.
#   make notarize NOTARY_ARGS="--key key.p8 --key-id ABC123 --issuer <uuid>"
NOTARY_ARGS      ?= --keychain-profile "$(NOTARY_PROFILE)"

.PHONY: all build sign sign-release pkg notarize dist clean install uninstall reload

all: build

build: $(BUNDLE)

$(BUNDLE): $(SRC) Info.plist
	rm -rf $(BUNDLE) $(BUILD)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUILD)
	# Swift can't emit a fat binary in one pass, so build each slice then lipo.
	for arch in $(ARCHS); do \
		swiftc $(SWIFTFLAGS) -target $$arch-apple-macos$(DEPLOY) \
			-module-name $(EXEC) -o $(BUILD)/$(EXEC)-$$arch $(SRC); \
	done
	lipo -create $(addprefix $(BUILD)/$(EXEC)-,$(ARCHS)) -output $(BUNDLE)/Contents/MacOS/$(EXEC)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	# coreaudiod on Apple Silicon refuses unsigned HAL plug-ins; ad-hoc ("-") is enough locally.
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(BUNDLE)
	rm -rf $(BUILD)
	@echo "Built $(BUNDLE)"

# --- Distribution targets ----------------------------------------------------

# Re-sign the built bundle with a Developer ID Application identity, hardened
# runtime, and a secure timestamp — the prerequisites for notarization.
sign-release: build
	codesign --force --options runtime --timestamp \
		--sign "$(DEV_ID_APP)" $(BUNDLE)
	codesign --verify --strict --verbose=2 $(BUNDLE)
	@echo "Signed $(BUNDLE) with Developer ID (hardened runtime)."

# Build a signed installer package that drops the driver into the system HAL
# directory and restarts coreaudiod. Requires a Developer ID Installer cert.
pkg: sign-release
	rm -rf $(BUILD)/pkgroot $(PKG)
	mkdir -p $(BUILD)/pkgroot
	cp -R $(BUNDLE) $(BUILD)/pkgroot/
	pkgbuild --root $(BUILD)/pkgroot \
		--identifier $(PKG_ID) \
		--version $(VERSION) \
		--install-location "$(HAL_DIR)" \
		--scripts packaging/scripts \
		--sign "$(DEV_ID_INSTALLER)" \
		$(PKG)
	rm -rf $(BUILD)/pkgroot
	@echo "Built signed installer: $(PKG)"

# Submit the package to Apple's notary service and staple the ticket so the
# result verifies offline. Requires a stored notarytool credential profile.
notarize: pkg
	xcrun notarytool submit $(PKG) $(NOTARY_ARGS) --wait
	xcrun stapler staple $(PKG)
	xcrun stapler validate $(PKG)
	@echo "Notarized and stapled: $(PKG)"

# Full distribution pipeline: signed, packaged, notarized, stapled.
dist: notarize

# Install into the system HAL directory and restart the audio daemon.
install: build
	sudo rm -rf "$(HAL_DIR)/$(BUNDLE)"
	sudo cp -R $(BUNDLE) "$(HAL_DIR)/"
	sudo chown -R root:wheel "$(HAL_DIR)/$(BUNDLE)"
	sudo killall coreaudiod || true
	@echo 'Installed. Select "Hush" in System Settings > Sound > Input.'

uninstall:
	sudo rm -rf "$(HAL_DIR)/$(BUNDLE)"
	sudo killall coreaudiod || true
	@echo "Uninstalled."

# Restart coreaudiod without reinstalling (useful after a manual copy).
reload:
	sudo killall coreaudiod || true

clean:
	rm -rf $(BUNDLE) $(BUILD)
