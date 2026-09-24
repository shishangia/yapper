# Yapper

<img src="Yapper/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Yapper's smiling chat bubble">

Local dictation and conversation transcription for macOS and Windows, maintained by Shivam Shishangia.

Yapper records from the microphone or imports an audio file, transcribes it on your device, and keeps the result in a local history. Conversation mode can add timestamped speaker turns that you can rename, reassign, merge, and edit.

## Install

**[Download Yapper for Mac](https://github.com/shishangia/yapper/releases/download/v1.0.3/Yapper-1.0.3-7-arm64.dmg)** | [Release notes and checksum](https://github.com/shishangia/yapper/releases/tag/v1.0.3)

1. Open the DMG and drag Yapper into Applications.
2. Open Yapper from Applications.
3. Allow microphone access for recording and Accessibility for global dictation and auto-paste. You can skip both permissions when you only want to import files.
4. Download a model in AI Models and click Use. Transcribe Audio may ask for an additional speech or speaker model.

The Mac installer is Developer ID signed and notarized by Apple. It requires macOS 14 or later on an Apple Silicon Mac. The current source version is 1.1.0. It fixes WhatsApp `.opus` imports, adds the real four-layer Whisper Turbo model, records processing timings, improves offline dictation cleanup, and lets conversation transcripts switch between paragraphs and timestamps. The published installer remains 1.0.3 until the next notarized release.

## Windows preview

**[Download the Windows 11 x64 preview](https://github.com/shishangia/yapper/releases/download/windows-v0.1.0-preview.2/Yapper-0.1.0-preview.2-win-x64-setup.exe)** | [Preview notes and checksum](https://github.com/shishangia/yapper/releases/tag/windows-v0.1.0-preview.2)

The Windows app is a separate native implementation with the same visual identity and local-first behavior. It includes tray dictation, a configurable shortcut, the floating recording pill, file import, editable speaker turns, history, dictionary rules, and Light, Dark, and System themes. The current source version is preview 3; the download above remains preview 2 until the next installer is published. The default shortcut is Ctrl+Alt+Space because Fn is firmware-controlled on many Windows keyboards.

Windows inference currently uses the CPU. Start with Whisper Tiny or Small on a modest PC. The installer is an unsigned preview, so Windows may show a SmartScreen warning. Do not weaken Windows security settings to install it. Windows data stays under `%LOCALAPPDATA%\Yapper` and does not sync with the Mac library. Physical microphone, shortcut, browser-paste, and performance testing still need to be completed on user hardware.

## Features

- Hold or toggle a global shortcut for dictation, with clipboard restoration and a compact recording window.
- Use local Whisper or Parakeet models. The selected model applies to dictation, microphone conversations, and imported files.
- Import audio and video for conversation transcription. Mac 1.1.0 source also handles WhatsApp `.opus` files.
- Switch conversation copy and reading views between clean paragraphs and timestamped turns without transcribing again.
- Use offline dictation cleanup for safe filler removal, capitalization, explicit lists and paragraph commands, and bounded “scratch that” corrections.
- Add optional local speaker labels for up to four people with Sortformer. Speaker names stay within one recording. Yapper does not store voice profiles or recognize people across recordings.
- Review timestamped turns, correct text and speakers, and keep changes after reopening the app. Corrections do not create duplicate history or statistics entries.
- Keep recordings, transcripts, dictionary entries, preferences, and model files in local app storage.
- Cancel safely. Active native inference finishes before another job starts, but canceled results are not saved or pasted.

Conversation transcripts bypass personal dictionary replacements and dictation cleanup. Yapper preserves the original recording and keeps uncertain speaker attribution visible for review.

Auto Edit is deterministic. It follows explicit formatting commands but does not yet infer tone, rewrite prose, or guess list structure with a language model.

## Models, privacy, and limits

Model downloads connect to Hugging Face and may follow its download redirects. After the required files are downloaded, transcription and speaker processing run locally. Yapper does not use a cloud transcription API, upload audio, collect analytics, or create stored voice profiles. Release builds may contact GitHub for update metadata.

Whisper supports many languages, including English, Hindi, Gujarati, and Chinese, but accuracy varies. Rapid language switching remains experimental and can cause omissions, repetition, transliteration, or translation. Parakeet v3 supports 25 European languages, not Hindi, Gujarati, or Chinese.

Automatic speaker labels can split one voice or confuse short replies and overlapping speech. Choose One speaker for a known single-person recording to skip speaker detection and word alignment. Important medical, legal, or financial transcripts should always be checked against the recording.

Full Whisper Large v3 needs roughly 3 GB of model storage and is recommended for Macs with at least 16 GB of memory. Large v3 Turbo is intended for lower-latency dictation. The speed and accuracy bars in Yapper are relative estimates, not measured benchmarks.

## Updates

Mac 1.0.3 and Windows preview 2 add Check for updates in Settings. Yapper checks GitHub at launch when the last successful check is more than 24 hours old, unless you turn automatic checks off. It never installs an update without confirmation or while recording, transcribing, or downloading a model.

The Mac updater checks the SHA-256, bundle version, Developer ID team, and Gatekeeper result before replacing the app. It keeps a rollback copy and leaves the separate local library in place. The Windows updater verifies the installer size and checksum, then opens the normal installer. It does not bypass SmartScreen.

## Permissions and local data

Microphone access is needed only for recording. Accessibility enables global shortcuts and pasting into another app. If dictation reaches History and manual Cmd+V works but auto-paste fails, remove Yapper from System Settings > Privacy & Security > Accessibility, add `/Applications/Yapper.app` again, enable it, then reopen Yapper. A signing-certificate change can make an old permission entry look enabled while macOS rejects it.

Mac data is stored in `~/Library/Application Support/Yapper`, with preferences under `com.shishangia.yapper`. Debug builds use `Yapper-Dev` and `com.shishangia.yapper.dev`, and their global shortcuts are disabled so they cannot interfere with the installed app. Yapper records microphone audio only, not system audio. Record other people only with their consent.

## Build and test

The Mac app uses SwiftUI, AppKit, AVFoundation, [WhisperKit](https://github.com/argmaxinc/WhisperKit), [FluidAudio](https://github.com/FluidInference/FluidAudio), and [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts). Exact dependency versions are in `Package.resolved`.

```sh
git clone https://github.com/shishangia/yapper.git
cd yapper
make build
make run
make test
```

The default build uses ad-hoc signing. A signed Release build is required for system-wide dictation. Maintainers can create the notarized DMG with a Developer ID Application certificate and Keychain-backed `notarytool` profile:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" \
APPLE_TEAM_ID="YOUR_TEAM_ID" \
NOTARY_PROFILE="yapper-notary" \
make dmg
```

The packaging script adds dependency notices, verifies the app, submits the app and DMG to Apple, checks the installer layout, and writes a SHA-256 sidecar. It does not upload a release or replace an installed app. Never commit signing credentials, certificates, model files, recordings, or test transcripts.

Windows developers need .NET 10. Run `dotnet run --project windows/Yapper.Core.Tests` for core tests and `dotnet run --project windows/Yapper.Windows` for the app. `scripts/package-windows.ps1` creates the preview installer on Windows with Inno Setup 6.

## License

Yapper is based on [SpeakType](https://github.com/karansinghgit/speaktype) v1.3.0 by Karan Singh. [LICENSE](LICENSE) keeps Karan Singh's original MIT notice and adds Shivam Shishangia's copyright for Yapper's changes. Dependency code and downloaded model weights retain their own licenses and terms.
