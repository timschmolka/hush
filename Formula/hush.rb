class Hush < Formula
  desc "Silent virtual microphone that keeps AirPods in full audio quality"
  homepage "https://github.com/timschmolka/hush"
  url "https://github.com/timschmolka/hush/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "7795a7d9df4d123cdfec7f6195f62c57ba2f116c3250a6a37da5eeba1d5ce2d2"
  license "MIT"
  head "https://github.com/timschmolka/hush.git", branch: "main"

  depends_on :macos
  depends_on xcode: :build

  def install
    system "make", "build"
    # A CoreAudio HAL plug-in must ultimately live in /Library/Audio/Plug-Ins/HAL,
    # which needs root — so Homebrew only stages the built bundle here. See caveats.
    prefix.install "Hush.driver"
  end

  def caveats
    <<~EOS
      Hush is a CoreAudio driver and must be copied into the system HAL directory,
      which requires administrator rights. To activate it:

        sudo cp -R "#{opt_prefix}/Hush.driver" /Library/Audio/Plug-Ins/HAL/
        sudo killall coreaudiod

      Then choose "Hush" in System Settings > Sound > Input.

      To deactivate:

        sudo rm -rf /Library/Audio/Plug-Ins/HAL/Hush.driver
        sudo killall coreaudiod
    EOS
  end

  test do
    assert_predicate prefix/"Hush.driver/Contents/MacOS/Hush", :exist?
    assert_match "BUNDLE", shell_output("otool -hv #{prefix}/Hush.driver/Contents/MacOS/Hush")
  end
end
