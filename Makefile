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

.PHONY: all build sign clean install uninstall reload

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
