import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader()
                .padding(.horizontal, 18)
                .padding(.top, 52)
                .padding(.bottom, 24)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SidebarItem.allCases) { item in
                        SidebarButton(
                            item: item,
                            isSelected: selection == item,
                            action: { selection = item }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Navigation")

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Shivam")
                    .font(Typography.labelMedium)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("sidebarSignature")

                #if DEBUG
                    Text(buildVersionString)
                        .font(Typography.monoSmall)
                        .foregroundStyle(Color.textMuted)
                #endif
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(Color.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.borderSubtle)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
    }

    private var buildVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version) (\(buildTimestamp))"
    }
}

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(decorative: "AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            Text("Yapper")
                .font(Typography.sidebarLogo)
                .foregroundStyle(Color.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SidebarButton: View {
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentPrimary : Color.textSecondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(item.rawValue)
                    .font(isSelected ? Typography.sidebarItemActive : Typography.sidebarItem)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(SelectionBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case dictionary = "Dictionary"
    case statistics = "Statistics"
    case aiModels = "AI Models"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .transcribeAudio: return "waveform"
        case .history: return "doc.text"
        case .dictionary: return "character.book.closed"
        case .statistics: return "chart.bar"
        case .aiModels: return "cpu"
        case .settings: return "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .dashboard: return "sidebar.dashboard"
        case .transcribeAudio: return "sidebar.transcribeAudio"
        case .history: return "sidebar.history"
        case .dictionary: return "sidebar.dictionary"
        case .statistics: return "sidebar.statistics"
        case .aiModels: return "sidebar.aiModels"
        case .settings: return "sidebar.settings"
        }
    }
}
