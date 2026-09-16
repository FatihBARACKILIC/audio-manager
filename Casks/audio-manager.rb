cask "audio-manager" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/FatihBARACKILIC/audio-manager/releases/download/v#{version}/AudioManager-#{version}.zip",
      verified: "github.com/FatihBARACKILIC/audio-manager/"
  name "Audio Manager"
  desc "Menu bar app for per-app volume, mute and equalizer"
  homepage "https://github.com/FatihBARACKILIC/audio-manager"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "AudioManager.app"

  uninstall launchctl: "com.barackilic.AudioManager",
            quit:      "com.barackilic.AudioManager"

  zap trash: [
    "~/Library/Application Support/com.barackilic.AudioManager",
    "~/Library/Containers/com.barackilic.AudioManager",
    "~/Library/Preferences/com.barackilic.AudioManager.plist",
  ]

  caveats do
    <<~EOS
      Audio Manager runs in the menu bar and has no Dock icon.

      The first time you mute or adjust an app, macOS asks for permission to record
      system audio. That prompt is unavoidable: macOS treats controlling another app's
      volume as capturing it. Audio Manager never records, stores or sends any audio,
      and makes no network connections at all.
    EOS
  end
end
