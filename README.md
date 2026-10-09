# Yapper

<img src="Yapper/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Yapper's smiling chat bubble">

Free, private dictation for Mac and Windows. Hold a key, speak, and the text lands in whatever app you were typing in. Everything runs on your computer.

## Download

**[Latest release](https://github.com/shishangia/yapper/releases/latest)**: the Mac disk image (`.dmg`, Apple Silicon, macOS 14 or later) and the Windows installer (`.exe`, Windows 11 x64), with checksums.

Mac: open the DMG and drag Yapper into Applications. Allow microphone access, and Accessibility access so Yapper can paste for you. The app is signed and notarized by Apple.

Windows: run the installer. It is not code signed yet, so SmartScreen may warn; do not turn off Windows security to install it. The default shortcut is Ctrl+Alt+Space.

Both apps check GitHub for updates and ask before installing one.

## What it does

- Hold or toggle a shortcut to dictate into any app. A small overlay shows a live draft while you speak.
- Cleans up what you said: filler sounds, accidental repeats, capitalization, and spoken commands such as "new paragraph", "bullet point", "scratch that" and "at the rate" for "@". On macOS 26 with Apple Intelligence turned on, an optional on-device pass tidies the text further, and the original is always kept in History.
- Learns your names. Fix a misheard word right after Yapper pastes it (Mac) or in History, and it goes into your preferred words.
- Transcribes audio files and microphone conversations, with optional speaker labels for up to eight people and timestamped turns you can edit. The Mac app also reads WhatsApp `.opus` voice notes.
- Speaks your languages. New installs default to Hindi-English (Hinglish) in Latin script; Whisper covers many more, and Parakeet is a fast option for English and European languages.
- Keeps recordings, transcripts, preferred words and snippets on your computer.

## Privacy

Audio and text never leave your computer. The only network use is downloading a model you choose from Hugging Face and checking GitHub for updates. There are no accounts, analytics, or stored voice profiles.

Mac data lives in `~/Library/Application Support/Yapper`; Windows data in `%LOCALAPPDATA%\Yapper`. Yapper records the microphone only, never system audio. Record other people only with their consent.

## If auto-paste stops working on Mac

Remove Yapper from System Settings > Privacy & Security > Accessibility, add `/Applications/Yapper.app` again, turn it on, and reopen Yapper. This happens after a signing change makes an old permission entry stale.

## Build from source

Mac: `make build`, `make run`, `make test`. The app uses SwiftUI, [WhisperKit](https://github.com/argmaxinc/WhisperKit), [FluidAudio](https://github.com/FluidInference/FluidAudio) and [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts). A notarized DMG needs a Developer ID certificate and a `notarytool` profile: `SIGN_IDENTITY="..." APPLE_TEAM_ID="..." NOTARY_PROFILE="..." make dmg`.

Windows: .NET 10, Rust with the `x86_64-pc-windows-msvc` target, and Inno Setup 6. `dotnet run --project windows/Yapper.Core.Tests` runs the core tests; `scripts/package-windows.ps1` builds the installer.

## License

Yapper started as a fork of [SpeakType](https://github.com/karansinghgit/speaktype) by Karan Singh. [LICENSE](LICENSE) keeps the original MIT notice and adds Shivam Shishangia's copyright for Yapper's changes. Dependencies and downloaded model weights keep their own licenses.
