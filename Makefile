# MockInput — build & install a virtual audio input driver for macOS.

BUNDLE     := MockInput.driver
EXEC       := MockInput
SRC        := src/MockAudio.c
HAL_DIR    := /Library/Audio/Plug-Ins/HAL
CODESIGN_IDENTITY ?= -

CFLAGS     := -O2 -Wall -Wextra -mmacosx-version-min=11.0
ARCHS      := -arch arm64 -arch x86_64
FRAMEWORKS := -framework CoreFoundation -framework CoreAudio

.PHONY: all build sign clean install uninstall reload

all: build

build: $(BUNDLE)

$(BUNDLE): $(SRC) Info.plist
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	clang -bundle $(CFLAGS) $(ARCHS) -o $(BUNDLE)/Contents/MacOS/$(EXEC) $(SRC) $(FRAMEWORKS)
	# coreaudiod on Apple Silicon refuses unsigned HAL plug-ins; ad-hoc ("-") is enough locally.
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(BUNDLE)
	@echo "Built $(BUNDLE)"

# Install into the system HAL directory and restart the audio daemon.
install: build
	sudo rm -rf "$(HAL_DIR)/$(BUNDLE)"
	sudo cp -R $(BUNDLE) "$(HAL_DIR)/"
	sudo chown -R root:wheel "$(HAL_DIR)/$(BUNDLE)"
	sudo killall coreaudiod || true
	@echo 'Installed. Select "Mock Input" in System Settings > Sound > Input.'

uninstall:
	sudo rm -rf "$(HAL_DIR)/$(BUNDLE)"
	sudo killall coreaudiod || true
	@echo "Uninstalled."

# Restart coreaudiod without reinstalling (useful after a manual copy).
reload:
	sudo killall coreaudiod || true

clean:
	rm -rf $(BUNDLE)
