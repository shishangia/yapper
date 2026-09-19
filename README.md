# Yapper

<img src="Yapper/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Yapper's smiling chat bubble">

Local dictation and conversation transcription for macOS, maintained by Shivam Shishangia.

Yapper transcribes microphone recordings and imported audio on your Mac. Use a hotkey for dictation, or record a conversation and review its timestamped speaker turns afterward. Switching pages or closing a window does not cancel a conversation job.

## Download and install

**[Download Yapper for Mac](https://github.com/shishangia/yapper/releases/download/v1.0.2/Yapper-1.0.2-6-arm64.dmg)** · [Release notes and checksum](https://github.com/shishangia/yapper/releases/tag/v1.0.2)

1. Open the downloaded DMG and drag **Yapper** into **Applications**.
2. Eject the DMG, then open Yapper from Applications.
3. Enable microphone access for recording and Accessibility for auto-paste, or continue without permissions to import files.
4. Download a model in **AI Models**, then click **Use**. Before going offline, open **Transcribe Audio** with your intended model and speaker mode, then choose **Download required models** if shown. Whisper conversations need a speech-detection model even when speaker labels are off; automatic speaker detection also needs Sortformer.

The app and installer are Developer ID signed and notarized by Apple. You do not need Terminal, Xcode, or `make`. macOS may still show its normal first-open and privacy prompts.

Requires **macOS 14 or later on Apple Silicon (M1 or newer)**. This installer does not support Intel Macs or Windows. An internet connection is needed for model downloads; transcription runs locally afterward.

## Windows preview

**[Download the Windows 11 x64 preview](https://github.com/shishangia/yapper/releases/download/windows-v0.1.0-preview.1/Yapper-0.1.0-preview.1-win-x64-setup.exe)** · [Preview notes and checksum](https://github.com/shishangia/yapper/releases/tag/windows-v0.1.0-preview.1)

A separate native Windows app lives under `windows/`; it does not replace the Mac app. It targets Windows 11 x64 (Intel/AMD) and runs Whisper or Parakeet locally, with optional speaker separation, editable recording-specific speaker names, history/playback, dictionary rules, and tray dictation.

The preview uses CPU inference and platform-specific model files. Start with Whisper Tiny or Small on a modest PC; Large v3 needs substantially more memory and processing time. Parakeet v3 does not support Hindi, Gujarati, or Chinese. Automatic speaker labels remain approximate and can require correction.

The default shortcut is **Ctrl+Alt+Space**, configurable in Settings. Fn is firmware-controlled on many Windows keyboards. Closing the window leaves Yapper in the tray. Auto-paste can be blocked by elevated target apps; Yapper falls back to the clipboard rather than bypassing Windows security. Microphone recording needs the Windows microphone permission. File import supports WAV, MP3, M4A, WMA, and AIFF through installed Windows codecs; unsupported files show an error. The preview limits recordings to two hours.

Windows data stays under `%LOCALAPPDATA%\Yapper`, separately from the Mac library. There is no automatic sync, GPU setup, or cross-platform model-cache sharing. Failed transcription can retry retained audio during the current session, but retry state does not survive restart.

The Windows installer bundles .NET and native runtime dependencies, so users do not need developer tools. It is an **unsigned test build**, not equivalent to the notarized Mac release; SmartScreen may report an unknown publisher. Do not disable Windows security settings to install it.

Windows CI checks the core data rules, real native speech/speaker processing with synthetic audio, actual textbox paste and clipboard restoration, installer execution, and native history/editor navigation. Physical microphone/hotkey behavior, browser-specific paste, and performance on a user's PC still need validation. The Mac's mature speaker-review presentation and the Windows preview are not yet identical.

To build on Windows with .NET 10:

```powershell
dotnet run --project windows/Yapper.Core.Tests
dotnet run --project windows/Yapper.Windows
```

Maintainers can run `scripts/package-windows.ps1` on a Windows build machine with Inno Setup 6 and the Visual C++ redistributable files. GitHub's Windows preview workflow produces the same installer and SHA-256 sidecar.

## What is new in 1.0.2

Downloads keep their progress when you change pages, cancellation preserves shared model files, and the selected downloaded model prepares for use. Escape dismisses the dictation recorder and prevents auto-paste while native work finishes; the dictation transcript still goes to History. Conversation cancellation discards pending results.

Setup can finish without permissions for file imports. Recent transcriptions support Play/Pause, shortcut hints match your configured key, and Settings offers **Trim final period on short dictation**. That setting is on by default and affects new dictation only, after dictionary replacements. It leaves sentences, dotted abbreviations, and conversation transcripts unchanged.

## What it does

- Hotkey dictation with hold and toggle recording modes, clipboard restoration, and a compact recorder.
- Local Whisper and Parakeet models, managed from AI Models.
- Conversation transcription with your selected Whisper or Parakeet model and optional Sortformer speaker labels for up to four people.
- Editable transcript turns, recording-specific speaker names, reassignment, and speaker merging.
- History with audio playback, a personal dictionary, statistics, input-device selection, and light/dark appearance.
- Explicit cancellation that waits for active native inference to finish before another job starts.

The model selected in AI Models controls dictation, microphone conversations, and imported files. Each job keeps the model selected when it starts. Conversation transcripts bypass personal dictionary replacements and dictation cleanup. Speaker detection uses a separate local model.

Speed and accuracy bars are relative estimates, not measured benchmarks or accuracy percentages. English-only models cannot transcribe other languages; Parakeet v3 supports 25 European languages, not Hindi, Gujarati, or Chinese. Choose a multilingual Whisper model for those languages.

## Requirements

- macOS 14 or newer on Apple Silicon.
- Xcode 26 or newer only if you want to build from source.
- Space for the models you choose, plus working storage. Full Large v3 and its conversation support models require roughly 3.2 GB; smaller model choices need less.
- Enough memory for the chosen model. Full Large v3 is recommended for Macs with at least 16 GB RAM.

## Build from source

```sh
git clone https://github.com/shishangia/yapper.git
cd yapper
make build
make run
```

Debug builds use `Yapper-Dev.app`, a separate preferences domain and library. Global dictation hotkeys are disabled in Debug; use Transcribe Audio for microphone and file testing. A signed Release build is needed to test system-wide dictation. The build output goes to `~/Library/Developer/Xcode/DerivedData/Yapper`, outside the protected Documents directory. The scripts never terminate an installed app or replace it automatically.

The default build uses ad-hoc signing. To use your own installed Apple Development certificate:

```sh
SIGN_IDENTITY="Apple Development: Your Name (CERTIFICATE_ID)" \
APPLE_TEAM_ID="YOUR_TEAM_ID" \
make release
```

Find installed signing identities with `security find-identity -v -p codesigning`. Do not commit certificates, private keys, provisioning profiles, or signing credentials.

A Release build produces `~/Library/Developer/Xcode/DerivedData/Yapper/Build/Products/Release/Yapper.app`. Quit an older installed copy before replacing it. New app identities or signing certificates may require fresh macOS permission approval.

## Package a downloadable installer

For maintainers, `make dmg` builds a Release app, includes dependency license notices, signs it with Developer ID, and submits it to Apple for notarization. It creates a compressed DMG with an Applications shortcut, setup instructions, and a SHA-256 checksum under `dist/`. Both the app and disk image must pass notarization and Gatekeeper checks before this command succeeds. It does not upload to GitHub or replace an installed app.

First create a Developer ID Application certificate using your Apple Developer account. Store notarization credentials in Keychain with `xcrun notarytool store-credentials`; use its secure password prompt, not a password in a command or source file. Then run:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)" \
APPLE_TEAM_ID="YOUR_TEAM_ID" \
NOTARY_PROFILE="yapper-notary" \
make dmg
```

`PACKAGES` can point to an existing Xcode `SourcePackages` directory. To package an already-built Release app, invoke `bash scripts/package-dmg.sh` directly with the same signing variables and optional `APP_PATH`. Keep the Mac unlocked and eject any existing **Install Yapper** volume before packaging. Finder saves the two-icon installation window and arrow background; the script checks that layout after ejecting and remounting the image read-only. Temporary build files stay under DerivedData.

`bash scripts/package-dmg.sh --local-test` makes an explicitly labeled, unnotarized local test image using `SIGN_IDENTITY`. It is not for distribution. Friends should only receive the notarized release: open the DMG, drag Yapper to Applications, and follow the in-app permission and model-download prompts. No Terminal or Xcode is needed on their Macs.

## Permissions and recording

Microphone access is needed for recording. Accessibility access is needed for global dictation shortcuts and pasting into other apps. File import does not require microphone access.

If Mac dictation appears in History and manual Cmd+V works but auto-paste does not, check Accessibility for the running app. A changed signing certificate can leave an old Yapper entry looking enabled while macOS rejects it. Quit Yapper, remove that entry, add `/Applications/Yapper.app` again, enable it, and reopen the app. Source builds now show a copy-only recovery message when permission or target focus blocks auto-paste; this feedback is newer than the v1.0.2 Mac download.

Yapper captures the microphone, not system audio. Obtain the consent of everyone being recorded. Speaker labels appear after processing; they do not identify real people automatically or create persistent voice profiles.

## Models and privacy

Model downloads connect to Hugging Face and may follow its download redirects. After the required files are present, transcription and speaker processing run locally. There is no Python service or cloud transcription API in the app.

The source-build version disables automatic app updates and does not contact the upstream licensing service. User-initiated external links open in the browser. Audio, transcripts, and dictionary entries are not part of this repository.

The local library is stored in `~/Library/Application Support/Yapper`. Preferences use `com.shishangia.yapper`; development builds use `Yapper-Dev` and `com.shishangia.yapper.dev`.

## Import an existing library

On first launch, Yapper can offer to copy a compatible local library from its predecessor. Quit the previous app before importing. Import copies recordings, dictionary entries, history, statistics, downloaded models, and the selected dictation model. It rewrites copied audio paths for Yapper and verifies file contents without modifying the original library.

An interrupted copy can be retried. Existing destination files must match exactly; Yapper stops on conflicts instead of overwriting different data. Keep your previous app and library until you have checked the import.

## Recognition limits

Whisper supports many languages, but support does not guarantee accuracy. Rapid Hindi-English-Gujarati switching remains experimental and can produce omissions, repetition, transliteration, or unintended translation. Select the known language when appropriate and check important passages against the audio.

Automatic speaker labels can split one voice or confuse short replies and overlap. Sortformer supports at most four speakers. Short uncertain passages stay within the reading flow, with underlined words instead of extra speaker headings. Review shows the original timestamped segments for correction. Grouping does not change speaker assignments; copied text uses a small footnote marker for uncertain words.

Choose One speaker before processing a known single-person recording to skip speaker detection and Whisper word alignment. Segment timestamps remain available. For an existing result, One speaker lets you confirm a recording-wide assignment without transcribing again. You can undo that correction after reopening the app, until you change a speaker name or assignment. Text edits and statistics are preserved.

Transcripts are drafts, especially for medical, legal, or other consequential use. Yapper preserves original transcript text when you edit a turn. Corrections do not create duplicate history or statistics entries.

## Tests

```sh
make test
```

Unit tests cover history compatibility, corrections, speech/timestamp alignment, reading groups, model selection, cancellation, session completion, and migration. They use isolated preferences and temporary files. Clipboard tests restore the prior clipboard afterward. The optional native-model smoke test requires `TEST_RUNNER_YAPPER_NATIVE_TESTS=1` and populated development caches; it copies its models and synthetic audio into temporary test storage.

The UI suite requires an unlocked desktop, model downloads in the development library, and a synthetic `conversation.wav` fixture under `~/Library/Application Support/Yapper-Dev/TestAudio`. It exercises importing, changing tabs during processing, renaming, editing, copying, and reopening history. Run it with Xcode's test navigator or `xcodebuild -only-testing:YapperUITests` alongside the usual project, scheme, destination, and signing arguments. Private recordings and test-result bundles must stay local.

## Development

The app uses SwiftUI, AppKit, AVFoundation, [WhisperKit](https://github.com/argmaxinc/WhisperKit), [FluidAudio](https://github.com/FluidInference/FluidAudio), and [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts). Exact package versions are recorded in `Package.resolved`.

`ConversationSession` owns conversation work independently of the views. `NativeInferenceGate` serializes native model work. `HistoryService` stores transcripts and separate statistics. The theme uses shared semantic colors and system fonts. The original app icon can be regenerated with `swift scripts/generate-icon.swift "$PWD"`.

## License and provenance

Yapper is based on [SpeakType](https://github.com/karansinghgit/speaktype) v1.3.0 by Karan Singh, with a redesigned interface and conversation workflow maintained by Shivam Shishangia. The original MIT copyright and permission notice are retained in [LICENSE](LICENSE). Dependency code and downloaded model weights retain their own licenses and usage terms.
