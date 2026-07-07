# Hush

**A silent virtual microphone for macOS that keeps your AirPods in full audio quality.**

[![Build](https://github.com/timschmolka/hush/actions/workflows/build.yml/badge.svg)](https://github.com/timschmolka/hush/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-11%2B-blue)
![Language](https://img.shields.io/badge/Swift-6-orange)

## The problem

Bluetooth headsets can't stream high-quality audio and act as a microphone at the same time. So the moment macOS selects your AirPods as the **input** device, it downgrades them from the high-quality **A2DP** codec to the mono, telephone-quality **SCO/HFP** codec — and your music suddenly sounds like a phone call.

The usual advice is "just set the input to another mic." That works on a MacBook with a built-in mic, but a **Mac Studio (or Mac mini) has no built-in microphone** and only one input, so there's nothing else to switch to.

**Hush** fixes that by adding a fake, always-silent input device. Select it as your microphone and macOS leaves your AirPods in full-quality output mode.

## How it works

Hush is a [CoreAudio Audio Server Plug-In](https://developer.apple.com/documentation/coreaudio/creating_an_audio_server_driver_plug-in) — a userspace HAL driver written in **Swift**, with no kernel extension and no SIP changes. It publishes a single device, **"Hush"**, with one input stream (48 kHz, stereo, Float32) that always reads silence. Any app that records from it simply gets quiet audio, while your Bluetooth output keeps its high-quality codec.

## Requirements

- macOS 11 (Big Sur) or later, Apple Silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`) to build from source

## Install

### Homebrew

```bash
brew install timschmolka/tap/hush
```

Homebrew builds and stages the driver, then prints the two `sudo` commands to activate it (a CoreAudio driver has to live in a system directory, which needs admin rights).

### From source

```bash
git clone https://github.com/timschmolka/hush.git
cd hush
make install     # builds, code-signs (ad-hoc), copies to the HAL dir, restarts coreaudiod
```

Then open **System Settings → Sound → Input** and choose **Hush**.

That's it — your AirPods now stay in full quality. All system audio drops for a second while `coreaudiod` restarts; that's expected.

## Uninstall

```bash
make uninstall
```

## Usage notes

- **Switch back when you actually need a mic.** Apps that record (calls, Voice Memos, Zoom) will get *silence* while Hush is selected. Pick your AirPods or a real mic before a call, then switch back to Hush for listening.
- macOS remembers the input per-app in some cases; if an app insists on the AirPods mic, set its input to something else too.

## Building without installing

```bash
make build      # produces ./Hush.driver (universal arm64 + x86_64)
make clean      # removes it
```

You can sign with a real identity instead of ad-hoc:

```bash
make build CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

## Troubleshooting

- **"Hush" doesn't appear.** Confirm the bundle is at `/Library/Audio/Plug-Ins/HAL/Hush.driver`, owned by `root:wheel`, then run `make reload`.
- **Check the logs.** The driver logs to the unified log:
  ```bash
  log stream --predicate 'subsystem == "com.timschmolka.hush"'
  ```
- **Verify it loaded.**
  ```bash
  system_profiler SPAudioDataType | grep -A2 Hush
  ```
- **Gatekeeper / signing.** On Apple Silicon `coreaudiod` won't load unsigned plug-ins; the build ad-hoc signs automatically, which is sufficient for local use. To distribute a prebuilt `.driver` to other machines you'll need a Developer ID signature and notarization.

## Project layout

```
src/Hush.swift    The entire driver (~430 lines, single file)
Info.plist        Plug-in factory registration
Makefile          build / install / uninstall / clean
Formula/hush.rb   Homebrew formula
```

## Prior art

If you want a full-featured virtual audio device (multiple channels, loopback, etc.), see [BlackHole](https://github.com/ExistentialAudio/BlackHole). Hush is intentionally minimal: one silent input, nothing else.

## License

MIT — see [LICENSE](LICENSE).
