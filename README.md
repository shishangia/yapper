# Yapper

<img src="Yapper/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Yapper's smiling chat bubble">

Local dictation and conversation transcription for macOS, maintained by Shivam Shishangia.

Yapper transcribes microphone recordings and imported audio on your Mac. Use a hotkey for dictation, or record a conversation and review its timestamped speaker turns afterward. Switching pages or closing a window does not cancel a conversation job.

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
- Xcode 26 or newer to build this source tree.
- Space for the models you choose, plus working storage. Full Large v3 and its conversation support models require roughly 3.2 GB; smaller model choices need less.
- Enough memory for the chosen model. Full Large v3 is recommended for Macs with at least 16 GB RAM.

This repository publishes source. It does not currently provide a notarized download or a binary release.

## Build and run

```sh
git clone https://github.com/shishangia/yapper.git
cd yapper
make build
make run
```

Debug builds use `Yapper-Dev.app`, a separate preferences domain and library. The build output goes to `~/Library/Developer/Xcode/DerivedData/Yapper`, outside the protected Documents directory. The scripts never terminate an installed app or replace it automatically.

The default build uses ad-hoc signing. To use your own installed Apple Development certificate:

```sh
SIGN_IDENTITY="Apple Development: Your Name (CERTIFICATE_ID)" \
APPLE_TEAM_ID="YOUR_TEAM_ID" \
make release
```

Find installed signing identities with `security find-identity -v -p codesigning`. Do not commit certificates, private keys, provisioning profiles, or signing credentials.

A Release build produces `~/Library/Developer/Xcode/DerivedData/Yapper/Build/Products/Release/Yapper.app`. Quit an older installed copy before replacing it. New app identities or signing certificates may require fresh macOS permission approval.

## Permissions and recording

Microphone access is needed for recording. Accessibility access is needed for global dictation shortcuts and pasting into other apps. File import does not require microphone access.

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

Automatic speaker labels can split one voice or confuse short replies and overlap. Sortformer supports at most four speakers. Choose One speaker for a known single-person recording, or correct and merge labels after transcription. The reading view groups short continuations and marks unassigned words inline; Review shows the original timestamped segments for editing. Grouping does not change speaker assignments, and copied text retains uncertainty markers.

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
