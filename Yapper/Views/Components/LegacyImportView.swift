import SwiftUI

struct LegacyImportView: View {
    @State private var migration = LegacyImportService.shared
    @AppStorage("legacyImportOffered") private var offered = false

    var body: some View {
        VStack(spacing: 24) {
            Image("AppLogo").resizable().scaledToFit().frame(width: 88, height: 88)
            Text("Make yourself at home").font(Typography.displayLarge)
            Text("Bring your existing local library into Yapper.")
                .font(Typography.bodyLarge).foregroundStyle(Color.textSecondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("History, recordings, dictionary and statistics", systemImage: "books.vertical")
                Label("Downloaded models and your current selection", systemImage: "cpu")
                Label("Original files remain unchanged", systemImage: "checkmark.shield")
            }
            .font(Typography.bodyMedium)
            .themedCard()
            if migration.isImporting {
                ProgressView("Copying and verifying your library…")
            } else {
                HStack {
                    Button("Start fresh") {
                        offered = true
                        NotificationCenter.default.post(name: .legacyLibraryImported, object: nil)
                    }.buttonStyle(.stSecondary)
                    Button("Import local library") { Task { await migration.importLibrary() } }
                        .buttonStyle(.stPrimary).accessibilityIdentifier("importLegacyLibrary")
                }
            }
            if let error = migration.error {
                Text(error).font(Typography.bodySmall).foregroundStyle(Color.accentError).textSelection(.enabled)
            }
        }
        .padding(40)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgContent)
        .onChange(of: migration.completed) {
            if migration.completed { offered = true }
        }
    }
}
