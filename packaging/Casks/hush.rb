# Homebrew cask template for distributing the notarized installer package.
#
# Finalize after `make dist` produces a notarized Hush-<version>.pkg and it is
# attached to the matching GitHub release:
#   1. Compute the checksum:  shasum -a 256 Hush-1.0.0.pkg
#   2. Paste it into `sha256` below.
#   3. Copy this file to the tap repo at Casks/hush.rb and push.
#
# Users then install with:  brew install --cask timschmolka/tap/hush
cask "hush" do
  version "1.0.0"
  sha256 "REPLACE_WITH_PKG_SHA256"

  url "https://github.com/timschmolka/hush/releases/download/v#{version}/Hush-#{version}.pkg"
  name "Hush"
  desc "Silent virtual microphone that keeps AirPods in full audio quality"
  homepage "https://github.com/timschmolka/hush"

  depends_on macos: ">= :big_sur"

  pkg "Hush-#{version}.pkg"

  uninstall pkgutil: "com.timschmolka.hush",
            quit:    "coreaudiod"

  caveats <<~EOS
    Hush adds a silent input device. Select it in
    System Settings > Sound > Input to keep Bluetooth output in full quality.
  EOS
end
