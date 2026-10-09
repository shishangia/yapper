import Combine
import SwiftUI

struct MainView: View {
    @State private var selection: SidebarItem? = .home
    @State private var settingsTab: SettingsTab = .general
    @Environment(ConversationSession.self) private var conversation
    @ObservedObject private var downloadService = ModelDownloadService.shared
    @AppStorage("hasShownModelPrompt") private var hasShownModelPrompt: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var learnedMessage: String?
    
    private var hasAnyModelDownloaded: Bool {
        downloadService.downloadProgress.values.contains { $0 >= 1.0 }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar - warmer background
            SidebarView(selection: $selection)
                .background(Color.bgSidebar)
            
            // Content area - white/light background
            ZStack {
                Color.bgContent
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if conversation.isBusy, selection != .transcribeAudio {
                        HStack(spacing: 12) {
                            Image(systemName: conversation.phase == .recording ? "mic.fill" : "waveform")
                                .foregroundStyle(Color.accentPrimary)
                            Text(conversation.status).font(Typography.labelMedium)
                            Spacer()
                            Button("View transcription") { selection = .transcribeAudio }
                                .buttonStyle(.stSecondary)
                                .accessibilityIdentifier("returnToTranscription")
                        }
                        .padding(16)
                        .background(Color.bgSurface)
                        Divider()
                    }
                    contentView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let learnedMessage { Toast(message: learnedMessage) }
            }
            .task(id: learnedMessage) {
                guard learnedMessage != nil else { return }
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(reduceMotion ? nil : .default) { learnedMessage = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .yapperLearnedWords).receive(on: RunLoop.main)) { note in
                let words = note.userInfo?["words"] as? [String] ?? []
                let full = note.userInfo?["full"] as? Bool ?? false
                guard full || !words.isEmpty else { return }
                withAnimation(reduceMotion ? nil : .default) {
                    learnedMessage = full ? "Preferred words are full" : "Learned \(words.formatted(.list(type: .and)))"
                }
            }
        }
        .background(Color.bgSidebar)
        .onAppear {
            // If no model downloaded and haven't shown prompt, go to Settings > Models
            if !hasAnyModelDownloaded && !hasShownModelPrompt {
                hasShownModelPrompt = true
                showModels()
            }
        }
    }
    
    private func showModels() {
        settingsTab = .models
        selection = .settings
    }

    @ViewBuilder
    private var contentView: some View {
        switch selection {
        case .home, .none:
            DashboardView(selection: $selection)
        case .transcribeAudio:
            TranscribeAudioView(showModels: showModels)
        case .history:
            HistoryView()
        case .dictionary:
            DictionaryView()
        case .settings:
            SettingsView(selectedTab: $settingsTab)
        }
    }
}
