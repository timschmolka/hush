# Homebrew cask for the notarized installer package.
# Canonical copy lives in the tap at Casks/hush.rb.
# On a new release, bump `version` and refresh `sha256` (the pkg checksum from
# the release's SHA256SUMS.txt).
#
# Install with:  brew install --cask timschmolka/tap/hush
cask "hush" do
  version "1.0.0"
  sha256 "7f0d81831d2a44a646d19d2b6d44858773220e7335043fe5555ae2f93af6d744"

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
