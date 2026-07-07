# Hush

**A silent virtual microphone for macOS that keeps your AirPods in full audio quality.**

[![Build](https://github.com/timschmolka/hush/actions/workflows/build.yml/badge.svg)](https://github.com/timschmolka/hush/actions/workflows/build.yml)
[![Release](https://github.com/timschmolka/hush/actions/workflows/release.yml/badge.svg)](https://github.com/timschmolka/hush/actions/workflows/release.yml)
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

Pick whichever you prefer — a signed, notarized installer (nothing to build), or a build from source.

### Homebrew — prebuilt installer (recommended)

```bash
brew install --cask timschmolka/tap/hush
```

Downloads the notarized `.pkg`, which installs the driver and restarts `coreaudiod` for you. Homebrew verifies the download's SHA-256 automatically, so a tampered file is rejected before it runs.

### Homebrew — build from source

```bash
brew install --formula timschmolka/tap/hush
```

Builds and stages the driver locally (needs the Xcode command-line tools), then prints the two `sudo` commands to activate it.

### From source, manually

```bash
git clone https://github.com/timschmolka/hush.git
cd hush
make install     # builds, code-signs (ad-hoc), copies to the HAL dir, restarts coreaudiod
```

Then open **System Settings → Sound → Input** and choose **Hush**.

That's it — your AirPods now stay in full quality. All system audio drops for a second while `coreaudiod` restarts; that's expected.

### Verifying a download

Every release ships a signed, notarized `.pkg` (verify with `spctl -a -vvv -t install Hush-1.0.0.pkg` — it should report *accepted / Notarized Developer ID*). The release notes also list the SHA-256 of each artifact so you can confirm it byte-for-byte:

```bash
shasum -a 256 Hush-1.0.0.pkg   # compare against the checksum in the release notes
```

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
src/Hush.swift        The entire driver (~430 lines, single file)
Info.plist            Plug-in factory registration
Makefile              build / install / uninstall / clean / dist
Formula/hush.rb       Homebrew formula (builds from source)
packaging/            postinstall script, Homebrew cask, CI secret helper,
                      and the release-notes template
.github/workflows/    build (CI) and release (sign + notarize + publish)
```

## Releasing (maintainer)

Releases are automated. Pushing a version tag triggers the
[Release workflow](.github/workflows/release.yml), which signs, notarizes, and
publishes the installer:

```bash
git tag v1.0.1 && git push origin v1.0.1
```

The workflow rebuilds a disposable keychain from the Developer ID certificates,
runs `make dist` (sign → package → notarize → staple), verifies the result with
`spctl`, and creates a GitHub release with the notarized `Hush-<version>.pkg`,
its `SHA256SUMS.txt`, and generated release notes. A manual
`workflow_dispatch` run does everything except publish — a full sign + notarize
dry run.

Per-release manual steps:

1. Bump `VERSION` in the `Makefile`.
2. After the release publishes, bump `version` and refresh `sha256` (the pkg
   checksum from the release's `SHA256SUMS.txt`) in the tap's `Casks/hush.rb`,
   and update `url`/`sha256` in `Formula/hush.rb` for the new source tarball.

### One-time CI setup

The workflow needs Developer ID certificates and an App Store Connect API key
for notarization, stored as repo secrets. `packaging/setup-ci-secrets.sh`
pushes them via `gh` (see its header for the exact export commands):

```bash
CERTS_P12=certs.p12 P12_PASSWORD='…' \
API_KEY_P8=AuthKey_XXXXXXXXXX.p8 API_KEY_ID=XXXXXXXXXX \
API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
./packaging/setup-ci-secrets.sh
```

### Building the installer locally

`make dist` produces the same Developer ID–signed, notarized package. It chains
`make sign-release` (hardened runtime + secure timestamp), `make pkg` (signed
`Hush-<version>.pkg`), and `make notarize` (submit + staple). This needs both
Developer ID certificates in the login keychain and notary credentials passed
via `NOTARY_ARGS` (a stored `notarytool` profile or an API key).

## Prior art

If you want a full-featured virtual audio device (multiple channels, loopback, etc.), see [BlackHole](https://github.com/ExistentialAudio/BlackHole). Hush is intentionally minimal: one silent input, nothing else.

## License

MIT — see [LICENSE](LICENSE).
