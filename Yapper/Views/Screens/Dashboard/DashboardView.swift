import AppKit
import SwiftUI

/// Home: words dictated, this week's activity, and recent transcripts.
struct DashboardView: View {
    @Binding var selection: SidebarItem?
    @StateObject private var historyService = HistoryService.shared
    private var transcription: TranscriptionManager { TranscriptionManager.shared }

    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = ModelSelection.defaultLanguage
    @AppStorage("selectedHotkey") private var selectedHotkey: HotkeyOption = .fn
    @AppStorage("recordingMode") private var recordingMode = 0

    private var weekStart: Date {
        Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var stats: HomeStats {
        let words = historyService.totalWordCount()
        let minutesSpoken = historyService.totalDuration() / 60
        return HomeStats(
            words: words,
            // Typing at an average 40 words per minute.
            minutesSaved: words / 40,
            wordsPerMinute: minutesSpoken >= 1 ? Int(Double(words) / minutesSpoken) : nil,
            todayCount: historyService.transcriptionCount(since: Calendar.current.startOfDay(for: Date())),
            weekWords: historyService.statsEntries(since: weekStart).reduce(0) { $0 + $1.wordCount }
        )
    }

    private var weeklyData: [(day: String, words: Int)] {
        let calendar = Calendar.current
        let entries = historyService.statsEntries(since: weekStart)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            let words = entries.filter { calendar.isDate($0.date, inSameDayAs: date) }.reduce(0) { $0 + $1.wordCount }
            return (formatter.string(from: date), words)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home")
                        .font(Typography.displayLarge)
                        .foregroundStyle(Color.textPrimary)
                    Text(selectedHotkey.recordingHint(mode: recordingMode))
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        StatsCard(stats: stats).frame(minWidth: 380)
                        ActivityChartCard(weeklyData: weeklyData).frame(width: 360)
                    }
                    VStack(spacing: 20) {
                        StatsCard(stats: stats)
                        ActivityChartCard(weeklyData: weeklyData)
                    }
                }

                recentTranscriptions
            }
            .padding(24)
        }
        .onAppear { transcription.warmSelectedModel() }
        .onChange(of: selectedModel) { transcription.warmSelectedModel() }
        .onChange(of: transcriptionLanguage) { transcription.warmSelectedModel() }
    }

    private var recentTranscriptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent transcriptions")
                        .font(Typography.headlineLarge)
                        .foregroundStyle(Color.textPrimary)

                    if !historyService.items.isEmpty {
                        Text(historyService.items.count == 1 ? "1 saved" : "\(historyService.items.count) saved")
                            .font(Typography.caption)
                            .foregroundStyle(Color.textMuted)
                    }
                }

                Spacer()

                if !historyService.items.isEmpty {
                    Button(action: { selection = .history }) {
                        HStack(spacing: 6) {
                            Text("View all")
                                .font(Typography.labelSmall)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if historyService.items.isEmpty {
                VStack(spacing: 6) {
                    Text("No transcriptions yet")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)

                    Text(selectedHotkey.recordingHint(mode: recordingMode))
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 12) {
                    ForEach(historyService.items.prefix(5)) { item in
                        RecentTranscriptionRow(item: item)
                    }
                }
            }
        }
        .themedCard()
    }
}

struct HomeStats {
    let words: Int
    let minutesSaved: Int
    let wordsPerMinute: Int?
    let todayCount: Int
    let weekWords: Int
}

// MARK: - Stats Card

struct StatsCard: View {
    let stats: HomeStats

    private var timeSaved: String {
        stats.minutesSaved < 60
            ? "\(stats.minutesSaved) min"
            : String(format: "%.1f h", Double(stats.minutesSaved) / 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stats.words.formatted())
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("words dictated")
                    .font(Typography.bodyLarge)
                    .foregroundStyle(Color.textSecondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                GridRow {
                    StatBlock(value: timeSaved, label: "Typing time saved")
                    StatBlock(value: stats.wordsPerMinute.map { "\($0) wpm" } ?? "None yet", label: "Speaking pace")
                }
                GridRow {
                    StatBlock(value: stats.todayCount.formatted(), label: "Transcriptions today")
                    StatBlock(value: stats.weekWords.formatted(), label: "Words this week")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
    }
}

// MARK: - Activity Chart Card

struct ActivityChartCard: View {
    let weeklyData: [(day: String, words: Int)]

    private var mostActiveDay: String? {
        guard let best = weeklyData.max(by: { $0.words < $1.words }), best.words > 0 else { return nil }
        return best.day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("This week")
                    .font(Typography.headlineLarge)
                    .foregroundStyle(Color.textPrimary)
                Text(mostActiveDay.map { "Words per day · most on \($0)" } ?? "Words per day")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 12) {
                let maxWords = max(weeklyData.map(\.words).max() ?? 1, 1)

                ForEach(weeklyData, id: \.day) { data in
                    VStack(spacing: 8) {
                        Text(data.words > 0 ? data.words.formatted(.number.notation(.compactName)) : " ")
                            .font(Typography.captionSmall)
                            .monospacedDigit()
                            .foregroundStyle(Color.textMuted)

                        RoundedRectangle(cornerRadius: 5)
                            .fill(data.words > 0 ? Color.accentPrimary : Color.border.opacity(0.4))
                            .frame(height: max(CGFloat(data.words) / CGFloat(maxWords) * 120, 6))

                        Text(data.day)
                            .font(Typography.captionSmall)
                            .foregroundStyle(data.words > 0 ? Color.textPrimary : Color.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(data.day), \(data.words) words")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedCard()
    }
}

// MARK: - Stat Block

struct StatBlock: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent Transcription Row (Multi-line)

struct RecentTranscriptionRow: View {
    let item: HistoryItem
    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    @State private var playbackError = false
    private var isPlaying: Bool { audioPlayer.currentAudioURL == item.audioFileURL && audioPlayer.isPlaying }
    @State private var isHovered = false
    @State private var showCopySuccess = false

    var wordCount: Int {
        item.transcript.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentPrimary)
                .frame(width: 32, height: 32)

            // Main content
            VStack(alignment: .leading, spacing: 8) {
                // Transcript - multiple lines
                Text(item.displayText.isEmpty ? "Empty transcription" : item.displayText)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                // Metadata row
                HStack(spacing: 12) {
                    // Time ago
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                        Text(timeAgo(item.date))
                    }
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)

                    // Word count
                    HStack(spacing: 4) {
                        Image(systemName: "text.word.spacing")
                            .font(.system(size: 11))
                        Text("\(wordCount) words")
                    }
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)

                    // Duration
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.system(size: 11))
                        Text(formatDuration(item.duration))
                    }
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)

                    Spacer()

                    // Quick actions
                    HStack(spacing: 8) {
                        // Copy button
                        Button(action: copyToClipboard) {
                            HStack(spacing: 4) {
                                Image(systemName: showCopySuccess ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11))
                                Text(showCopySuccess ? "Copied" : "Copy")
                                    .font(Typography.captionSmall)
                            }
                            .foregroundStyle(
                                showCopySuccess ? Color.accentSuccess : Color.textSecondary
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.bgHover)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        // Play audio button (if available)
                        if item.audioFileURL != nil {
                            Button(action: togglePlayback) {
                                HStack(spacing: 4) {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 11))
                                    Text(isPlaying ? "Pause" : "Play")
                                        .font(Typography.captionSmall)
                                }
                                .foregroundStyle(Color.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.bgHover)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("recent.play.\(item.id)")
                        }
                    }
                    .opacity(isHovered ? 1 : 0.5)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.bgHover.opacity(0.7) : Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .alert("Recording unavailable", isPresented: $playbackError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The audio file could not be played. Your transcript is still saved.")
        }
    }

    private func togglePlayback() {
        guard let url = item.audioFileURL else { return }
        if isPlaying { audioPlayer.pause(); return }
        if audioPlayer.currentAudioURL != url { audioPlayer.loadAudio(from: url) }
        guard audioPlayer.currentAudioURL == url else { playbackError = true; return }
        audioPlayer.play()
        playbackError = !audioPlayer.isPlaying
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.displayText, forType: .string)

        withAnimation {
            showCopySuccess = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopySuccess = false
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let mins = seconds / 60
            let secs = seconds % 60
            return "\(mins)m \(secs)s"
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
