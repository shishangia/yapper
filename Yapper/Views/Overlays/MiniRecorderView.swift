import AVFoundation
import Combine
import CoreMedia
import SwiftUI

struct MiniRecorderView: View {
    @ObservedObject private var audioRecorder = AudioRecordingService.shared
    private var transcription: TranscriptionManager { TranscriptionManager.shared }
    let job: RecorderJob
    private var isListening: Bool { job.isBusy && job.phase == .recording }
    private var isProcessing: Bool { job.isBusy && job.phase != .recording }
    @State private var statusMessage = "Transcribing..."
    var onCommit: ((String, RecorderJob.Snapshot) -> Void)?
    var onCancel: (() -> Void)?

    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage("recordingMode") private var recordingMode: Int = 0
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = ModelSelection.defaultLanguage
    @AppStorage("recentTranscriptionLanguages") private var recentLanguagesString: String = ""
    private let quickLanguageDefaults = ["hinglish", "en", "es", "fr", "de", "hi", "pt", "ja", "zh"]

    private var recentLanguageCodes: [String] {
        recentLanguagesString.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var quickLanguageCodes: [String] {
        var orderedCodes: [String] = []
        let candidateCodes = [transcriptionLanguage] + recentLanguageCodes + quickLanguageDefaults

        for code in candidateCodes where code != "auto" && code != "hinglish" {
            guard !orderedCodes.contains(code) else { continue }
            guard GeneralSettingsTab.whisperLanguages.contains(where: { $0.code == code }) else {
                continue
            }
            orderedCodes.append(code)
        }

        return Array(orderedCodes.prefix(6))
    }

    private func updateRecentLanguages(code: String) {
        guard code != "auto" else { return }
        var recents = recentLanguageCodes.filter { $0 != code }
        recents.insert(code, at: 0)
        recentLanguagesString = recents.prefix(5).joined(separator: ",")
    }

    private func setLanguage(_ code: String) {
        transcriptionLanguage = code
        updateRecentLanguages(code: code)
        transcription.warmSelectedModel()
    }

    private var currentLanguageLabel: String {
        if transcriptionLanguage == "auto" { return "Auto" }
        return spokenLanguageDisplayName(for: transcriptionLanguage)
    }

    private var spokenLanguageHelpText: String {
        if transcriptionLanguage == "auto" {
            return "Spoken language hint: Auto-detect. Yapper will try to detect the language you are speaking."
        }

        return
            "Spoken language hint: \(spokenLanguageDisplayName(for: transcriptionLanguage)). If this does not match the language you actually speak, the result may be inaccurate or come back in the wrong language."
    }

    private var currentInputDeviceName: String {
        guard
            let selectedDeviceId = audioRecorder.selectedDeviceId,
            let device = audioRecorder.availableDevices.first(where: { $0.uniqueID == selectedDeviceId })
        else {
            return "No input selected"
        }

        return device.localizedName
    }

    private var inputDeviceHelpText: String {
        "Input device: \(currentInputDeviceName). Change microphones without going back to Settings."
    }

    // MARK: - State for Escape key cancellation
    @State private var globalEscapeMonitor: Any?
    @State private var localEscapeMonitor: Any?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    // MARK: - State for Animation
    @State private var phase: CGFloat = 0

    /// Whether the pill is hovered — reveals the mic/mode/language controls inline.
    @State private var expanded = false

    /// Local recording start, set the moment we begin listening so the elapsed
    /// timer ticks reliably (independent of the service's non-published state).
    @State private var recordingStart: Date?

    /// Drives the soft pulse on the recording indicator dot.
    @State private var dotPulse = false

    // MARK: - Recorder helpers

    /// Compact language label for the always-visible tag ("Auto" or "EN").
    private var currentLanguageShort: String {
        if transcriptionLanguage == "auto" { return "Auto" }
        if transcriptionLanguage == "hinglish" { return "Hinglish" }
        return transcriptionLanguage.uppercased()
    }

    /// First word of the selected input device, for a compact chip ("MacBook").
    private var shortDeviceName: String {
        let name = currentInputDeviceName
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private func elapsedString(_ now: Date) -> String {
        guard let start = recordingStart ?? audioRecorder.recordingStartTime else { return "0:00" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Shared chip styling for the recorder's labeled controls (icon + word + chevron).
    private func recorderChipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
            DoubleChevronIcon(color: .textSecondary)
        }
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.bgHover))
    }

    private var languageControl: some View {
        Menu {
            Button("Hinglish · Latin script") { setLanguage("hinglish") }
            Button("Auto-detect") { setLanguage("auto") }
            if !quickLanguageCodes.isEmpty {
                Divider()
                ForEach(quickLanguageCodes, id: \.self) { code in
                    if code == "hinglish" {
                        Button("Hinglish · Latin script") { setLanguage(code) }
                    } else if let lang = GeneralSettingsTab.whisperLanguages.first(where: { $0.code == code }) {
                        Button(lang.name) { setLanguage(code) }
                    }
                }
            }
            Divider()
            Menu("More languages") {
                ForEach(GeneralSettingsTab.whisperLanguages, id: \.code) { lang in
                    Button(lang.name) { setLanguage(lang.code) }
                }
            }
            if !recentLanguageCodes.isEmpty {
                Divider()
                Button("Clear recents") { recentLanguagesString = "" }
            }
        } label: {
            recorderChipLabel(icon: "globe", text: currentLanguageShort)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .tint(Color.textPrimary)
        .fixedSize()
        .help(spokenLanguageHelpText)
    }

    private var micControl: some View {
        Menu {
            if audioRecorder.availableDevices.isEmpty {
                Button("No input devices found") {}.disabled(true)
            } else {
                ForEach(audioRecorder.availableDevices, id: \.uniqueID) { device in
                    Button {
                        selectAudioDevice(device.uniqueID)
                    } label: {
                        if audioRecorder.selectedDeviceId == device.uniqueID {
                            Label(device.localizedName, systemImage: "checkmark")
                        } else {
                            Text(device.localizedName)
                        }
                    }
                }
            }
            Divider()
            Button("Refresh inputs") { audioRecorder.fetchAvailableDevices() }
        } label: {
            recorderChipLabel(icon: "mic.fill", text: shortDeviceName)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .tint(Color.textPrimary)
        .fixedSize()
        .help(inputDeviceHelpText)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var modeControl: some View {
        Menu {
            Button {
                recordingMode = 0
            } label: {
                if recordingMode == 0 {
                    Label("Hold to talk", systemImage: "checkmark")
                } else {
                    Text("Hold to talk")
                }
            }
            Button {
                recordingMode = 1
            } label: {
                if recordingMode == 1 {
                    Label("Toggle on / off", systemImage: "checkmark")
                } else {
                    Text("Toggle on / off")
                }
            }
        } label: {
            recorderChipLabel(
                icon: recordingMode == 0 ? "hand.tap.fill" : "repeat.1",
                text: recordingMode == 0 ? "Hold" : "Toggle")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .tint(Color.textPrimary)
        .fixedSize()
        .help("Recording mode")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: - Live waveform
    // Samples come from AudioRecordingService.liveWaveSamples (peak amplitude per
    // audio buffer while recording). Rendered with a SwiftUI Canvas so it redraws
    // on every sample change.
    private static let waveBarWidth: CGFloat = 2.5
    private static let waveBarSpacing: CGFloat = 2.0

    // Default Init for Preview
    init(job: RecorderJob, onCommit: ((String, RecorderJob.Snapshot) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.job = job
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    // MARK: - Display phase & pill geometry

    /// The recorder is always on screen. `idle` is the tiny resting pill; the
    /// other phases are the expanded HUD it morphs into.
    private enum RecorderPhase { case idle, warming, processing, recording, feedback }

    private var displayPhase: RecorderPhase {
        #if DEBUG
        if let preview = ProcessInfo.processInfo.environment["YAPPER_RECORDER_PREVIEW"] {
            switch preview {
            case "recording": return .recording
            case "processing": return .processing
            case "warming": return .warming
            case "idle": return .idle
            default: break
            }
        }
        #endif
        if job.pasteFeedback?.message != nil { return .feedback }
        guard job.isPresented else { return .idle }
        if job.phase == .preparing { return .warming }
        if isProcessing { return .processing }
        if isListening { return .recording }
        return .idle
    }

    /// Width of the pill for the current phase. The frosted capsule animates
    /// between these, morphing the resting handle into the full HUD.
    private var pillWidth: CGFloat {
        switch displayPhase {
        case .idle: return 58
        case .warming: return 200
        case .processing: return statusMessage.count > 28 ? 490 : 210  // long notices use the feedback width
        case .feedback: return 490
        case .recording: return expanded ? 460 : 250
        }
    }

    private var pillHeight: CGFloat {
        displayPhase == .idle ? 24 : 44
    }

    private var pillCornerRadius: CGFloat { pillHeight / 2 }

    // MARK: - Phase content

    /// Resting state — a small white waveform silhouette that sits perfectly
    /// still. Calm, minimal, premium: the same quiet rest at first launch and
    /// after a recording, with no idle "breathing" motion.
    private var idleContent: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.idleBarScale.enumerated()), id: \.offset) { _, scale in
                Capsule(style: .continuous)
                    .fill(Color.accentPrimary)
                    .frame(width: 2.5, height: 12 * scale)
            }
        }
        .frame(height: 24)
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }

    private var warmingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.accentPrimary)
            Text("Warming up model...")
                .font(Typography.pillLabel)
                .foregroundColor(Color.textPrimary)
        }
        .transition(.opacity)
    }

    private var processingContent: some View {
        Text(statusMessage)
            .font(Typography.pillLabel)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .transition(.opacity)
    }

    private var recordingContent: some View {
        HStack(spacing: 10) {
            recordingDot

            // Waveform — live render of the actual microphone input.
            // Calm/flat when silent, peaks on speech.
            Canvas { context, size in
                let raw = audioRecorder.liveWaveSamples
                guard !raw.isEmpty else { return }
                let step = Self.waveBarWidth + Self.waveBarSpacing
                let maxBars = max(1, Int(size.width / step))
                // Samples are raw linear peak amplitude (0...1), which sits LOW on
                // the scale — so we auto-gain to your own recent peak, meaning your
                // voice always fills the bars no matter the mic level. Two knobs:
                //   noiseGate  – trim dead-silence hiss before measuring.
                //   presence   – fade the whole waveform toward flat when the loudest
                //                thing in view is only faint ambient sound (a fan).
                //                It reaches full quickly, so real speech is never
                //                dimmed — only near-silence collapses. Raise
                //                `presenceFull` if the fan still shows; lower it if
                //                quiet speech looks weak.
                let noiseGate: Float = 0.02
                let presenceFull: Float = 0.08
                let gated = raw.suffix(maxBars).map { max(0, $0 - noiseGate) }
                let peak = gated.max() ?? 0
                let recentPeak = max(peak, 0.05)
                let presence = CGFloat(min(1, peak / presenceFull))
                let midY = size.height / 2
                for (i, sample) in gated.enumerated() {
                    let norm = CGFloat(min(1, sample / recentPeak)) * presence
                    let barHeight = max(2.0, norm * size.height)
                    let x = CGFloat(i) * step
                    let rect = CGRect(
                        x: x, y: midY - barHeight / 2,
                        width: Self.waveBarWidth, height: barHeight)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: Self.waveBarWidth / 2),
                        with: .color(Color.textPrimary))
                }
            }
            .frame(height: 22)
            .frame(maxWidth: .infinity)

            // Elapsed recording time.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsedString(context.date))
                    .font(Typography.pillTime)
                    .foregroundColor(Color.textSecondary)
            }

            // Mic + mode + language: revealed inline on hover only, to keep
            // the resting state minimal.
            if expanded {
                micControl
                modeControl
                languageControl
            }
        }
        .padding(.horizontal, 14)
        .transition(.opacity)
    }

    /// Silhouette for the idle waveform — a soft, symmetric shape.
    private static let idleBarScale: [CGFloat] = [0.5, 0.85, 1.0, 0.85, 0.5]

    /// The morphing pill itself, sized to the current phase.
    private var pillView: some View {
        ZStack {
            backgroundView(cornerRadius: pillCornerRadius)

            switch displayPhase {
            case .warming:
                warmingContent
            case .processing:
                processingContent
            case .feedback:
                HStack(spacing: 10) {
                    Text(job.pasteFeedback?.message ?? "").font(Typography.pillLabel)
                    if job.pasteFeedback == .copiedPermissionMissing {
                        Button("Settings") { ClipboardService.shared.openAccessibilitySettings() }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("pasteFeedback")
            case .recording:
                recordingContent
            case .idle:
                idleContent
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recorder.\(displayPhase)")
        .accessibilityLabel(Text(verbatim: "Recorder \(displayPhase), \(job.isBusy ? "busy" : "ready")"))
        .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(displayPhase == .idle ? 0.35 : 0.45),
            radius: displayPhase == .idle ? 8 : 14,
            x: 0,
            y: displayPhase == .idle ? 3 : 5)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.92), value: displayPhase)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.92), value: expanded)
        .onHover { hovering in
            guard displayPhase == .recording else { return }
            expanded = hovering
        }
        .contextMenu {
            modelSelectionMenu
        }
    }

    var body: some View {
        // Fixed-size window; the pill is centered inside and morphs entirely in
        // SwiftUI. Because the window never resizes, the animation stays smooth
        // with no boundary clipping. Color.clear makes the root fill the window so
        // the pill is reliably centered.
        ZStack {
            Color.clear.allowsHitTesting(false)
            pillView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(appTheme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .recordingStartRequested)) { _ in
            startRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingStopRequested)) { _ in
            stopAndTranscribe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingCancelRequested)) { _ in
            cancelRecording()
        }
        .onAppear {
            initializedService()
            audioRecorder.fetchAvailableDevices()

            // Set up Escape key monitors
            globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    MainActor.assumeIsolated { self.handleEscape() }
                }
            }
            localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53, job.isBusy {
                    MainActor.assumeIsolated { self.handleEscape() }
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let globalEscapeMonitor = globalEscapeMonitor {
                NSEvent.removeMonitor(globalEscapeMonitor)
            }
            if let localEscapeMonitor = localEscapeMonitor {
                NSEvent.removeMonitor(localEscapeMonitor)
            }
            audioRecorder.stopSessionIfIdle()
        }
        .onChange(of: isListening) {
            // Only animate when actually recording to save CPU
            if isListening {
                recordingStart = Date()
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    phase = .pi * 4
                }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    dotPulse = true
                }
            } else {
                recordingStart = nil
                phase = 0
                dotPulse = false
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Ensure focus if needed
        }
        .background(
            KeyEventHandlerView(onEscape: {
                handleEscape()
            })
        )
    }

    // MARK: - Subviews

    /// Live recording indicator — a soft, pulsing red dot. Reads as "recording",
    /// not a button. Still tappable to stop for users who prefer clicking.
    private var recordingDot: some View {
        let core = Color(red: 1.0, green: 0.27, blue: 0.24)
        return Circle()
            .fill(core)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(core.opacity(0.35), lineWidth: 5)
                    .scaleEffect(dotPulse ? 2.1 : 1.0)
                    .opacity(dotPulse ? 0 : 0.9)
            )
            .shadow(color: core.opacity(0.6), radius: 4, x: 0, y: 0)
            .frame(width: 24, height: 24)  // stable hit + halo area
            .contentShape(Circle())
            .onTapGesture { handleHotkeyTrigger() }
            .help("Recording — click or press your hotkey to stop")
    }

    private func backgroundView(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape.fill(displayPhase == .idle ? Color.bgSelected : Color.bgSurface)
            .overlay(shape.strokeBorder(Color.border, lineWidth: 1))
    }

    @ViewBuilder
    private var modelSelectionMenu: some View {
        ForEach(AIModel.availableModels.filter { !$0.isLegacy || $0.variant == selectedModel }) { model in
            Button {
                if model.isHinglish {
                    transcriptionLanguage = ModelSelection.defaultLanguage
                } else {
                    selectedModel = model.variant
                    if transcriptionLanguage == ModelSelection.defaultLanguage {
                        transcriptionLanguage = "auto"
                    }
                }
                transcription.warmSelectedModel()
            } label: {
                if ModelSelection.displayedVariant(
                    selectedModel, language: transcriptionLanguage) == model.variant
                {
                    Label(model.name, systemImage: "checkmark")
                } else {
                    Text(model.name)
                }
            }
        }
    }

    // MARK: - Logic

    private func initializedService() {
        transcription.warmSelectedModel()
    }

    private func handleHotkeyTrigger() {
        if isListening { stopAndTranscribe() }
    }

    private func cancelRecording() {
        guard let snapshot = job.snapshot else { return }
        let wasRecording = isListening
        job.cancel()
        onCancel?()
        if wasRecording, job.transition(snapshot.id, from: .recording, to: .stopping) {
            Task {
                _ = await audioRecorder.stopRecording(discardOutput: true)
                finish(snapshot)
            }
        }
    }

    private func startRecording() {
        guard let snapshot = job.snapshot, job.phase == .preparing else { return }
        guard !snapshot.model.isEmpty else { showError("No model selected", for: snapshot); return }
        guard ModelStorage.transcriptionModelReady(snapshot.model) else {
            // Start (or keep) the download instead of recording audio no model can transcribe yet.
            let downloads = ModelDownloadService.shared
            downloads.downloadModel(variant: snapshot.model)
            let name = AIModel.availableModels.first { $0.variant == snapshot.model }?.name ?? "model"
            let percent = downloads.downloadProgress[snapshot.model].map { " \(Int($0 * 100))%" } ?? ""
            showError("Downloading \(name)\(percent). Dictate again when it finishes.", for: snapshot)
            return
        }
        do { try TranscriptionManager.validate(variant: snapshot.model, language: snapshot.language) }
        catch { showError("Choose a model for this language", for: snapshot); return }
        Task {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
            default: authorized = false
            }
            guard job.canCommit(snapshot.id) else { finish(snapshot); return }
            guard authorized else { showError("Enable Microphone in System Settings", for: snapshot); return }
            guard job.transition(snapshot.id, from: .preparing, to: .recording) else { return }
            audioRecorder.startRecording()
        }
    }

    private func selectAudioDevice(_ deviceId: String) {
        guard audioRecorder.selectedDeviceId != deviceId else { return }
        guard let snapshot = job.snapshot, isListening else {
            if !job.isBusy { audioRecorder.selectedDeviceId = deviceId }
            return
        }
        guard job.transition(snapshot.id, from: .recording, to: .switchingInput) else { return }
        statusMessage = "Switching input..."
        Task {
            _ = await audioRecorder.stopRecording(discardOutput: true)
            guard job.canCommit(snapshot.id) else { finish(snapshot); return }
            audioRecorder.selectedDeviceId = deviceId
            guard job.transition(snapshot.id, from: .switchingInput, to: .recording) else { return }
            audioRecorder.startRecording()
        }
    }

    private func stopAndTranscribe() {
        guard let snapshot = job.snapshot else { return }
        if job.phase == .preparing || job.phase == .switchingInput {
            job.cancel()
            onCancel?()
            return
        }
        guard job.transition(snapshot.id, from: .recording, to: .stopping) else { return }
        statusMessage = "Finishing recording..."
        Task {
            guard let url = await audioRecorder.stopRecording() else { finish(snapshot); return }
            guard job.transition(snapshot.id, from: .stopping, to: .processing) else { return }
            await processRecording(url: url, snapshot: snapshot)
        }
    }

    private func handleEscape() {
        guard job.isBusy else { return }
        let wasRecording = isListening
        job.cancel()
        onCancel?()
        // Escape retains dictation history, but never copies or pastes its result.
        if wasRecording { stopAndTranscribe() }
    }

    private func finish(_ snapshot: RecorderJob.Snapshot) {
        guard job.snapshot?.id == snapshot.id else { return }
        job.finish(snapshot.id)
        onCancel?()
    }

    private func showError(_ message: String, for snapshot: RecorderJob.Snapshot) {
        guard job.snapshot?.id == snapshot.id else { return }
        guard job.isPresented else { finish(snapshot); return }
        _ = job.transition(snapshot.id, from: .preparing, to: .processing)
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            finish(snapshot)
        }
    }

    private func debugLog(_ message: String) {
        // Do not write transcripts or recording paths to a shared temporary file.
    }

    private func processRecording(url: URL, snapshot: RecorderJob.Snapshot) async {
        do {
            if job.isPresented { statusMessage = "Transcribing..." }
            let output = try await transcription.transcribeDetailed(audioFile: url, variant: snapshot.model, language: snapshot.language)
            let trimPeriod = UserDefaults.standard.object(forKey: "trimDictationPeriod") as? Bool ?? true
            let text = DictationPunctuation.apply(to: output.text, enabled: trimPeriod)
            guard !text.isEmpty else { showError("No speech detected", for: snapshot); return }
            let duration = await getAudioDuration(url: url)
            let modelName = AIModel.availableModels.first(where: { $0.variant == snapshot.model })?.name ?? snapshot.model
            HistoryService.shared.addItem(transcript: text, duration: duration, audioFileURL: url,
                modelUsed: modelName, transcriptionTime: output.timing.total, dictationTiming: output.timing)
            if job.canCommit(snapshot.id), let onCommit {
                onCommit(text, snapshot)
            } else {
                finish(snapshot)
            }
        } catch {
            showError("Transcription failed", for: snapshot)
        }
    }

    private func getAudioDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return 0
        }
    }

    private func spokenLanguageDisplayName(for code: String) -> String {
        if code == "hinglish" { return "Hinglish (Latin script)" }
        if code == "auto" { return "Auto-detect" }
        return GeneralSettingsTab.whisperLanguages.first(where: { $0.code == code })?.name ?? code
    }
}

// MARK: - Helper Shapes & Views

struct ChevronShape: Shape {
    let pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if pointsUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        return path
    }
}

struct DoubleChevronIcon: View {
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            ChevronShape(pointsUp: true)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 7, height: 4)

            ChevronShape(pointsUp: false)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 7, height: 4)
        }
        .frame(width: 8, height: 10)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0
    /// Force a fixed vibrancy appearance (e.g. `.vibrantDark`) so the frosted
    /// glass stays dark/premium regardless of the system light/dark setting.
    var appearanceName: NSAppearance.Name? = nil

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active

        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true

        if let appearanceName {
            visualEffectView.appearance = NSAppearance(named: appearanceName)
        }

        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
        if let appearanceName {
            nsView.appearance = NSAppearance(named: appearanceName)
        }
    }
}

// MARK: - Key Event Handler

struct KeyEventHandlerView: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? KeyCaptureView {
            view.onEscape = onEscape
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    class KeyCaptureView: NSView {
        var onEscape: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {  // Escape key
                onEscape?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
