import XCTest
@testable import Yapper

@MainActor
final class LegacyImportServiceTests: XCTestCase {
    func testImportCopiesFilesAndCanRetryWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original")
        let target = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("Recordings/example.wav")
        let bytes = Data("test audio".utf8)
        try bytes.write(to: file)
        try LegacyImportService.copyVerifiedLibrary(from: source, to: target)
        try LegacyImportService.copyVerifiedLibrary(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Recordings/example.wav")), bytes)
        try Data("existing modification".utf8).write(to: target.appendingPathComponent("Recordings/example.wav"))
        XCTAssertThrowsError(try LegacyImportService.copyVerifiedLibrary(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPreferencesPreserveIdentifiersAndRemapOnlyOwnedAudio() throws {
        let source = URL(fileURLWithPath: "/original/library")
        let target = URL(fileURLWithPath: "/new/library")
        let id = UUID().uuidString
        let original: [[String: Any]] = [
            ["id": id, "transcript": "Original text", "audioFileURL": source.appendingPathComponent("Recordings/a.wav").absoluteString],
            ["id": UUID().uuidString, "audioFileURL": "file:///external/audio.wav"]
        ]
        let history = try JSONSerialization.data(withJSONObject: original)
        let dictionary = Data("[]".utf8)
        let prepared = try LegacyImportService.preparedPreferences([
            "history_items": history, "dictionary_entries": dictionary,
            "selectedModelVariant": "openai_whisper-large-v3_turbo", "secret": "excluded"
        ], source: source, destination: target)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(prepared["history_items"] as? Data)) as? [[String: Any]])
        XCTAssertEqual(decoded[0]["id"] as? String, id)
        XCTAssertEqual(decoded[0]["audioFileURL"] as? String, target.appendingPathComponent("Recordings/a.wav").absoluteString)
        XCTAssertEqual(decoded[1]["audioFileURL"] as? String, "file:///external/audio.wav")
        XCTAssertEqual(prepared["dictionary_entries"] as? Data, dictionary)
        XCTAssertEqual(prepared["selectedModelVariant"] as? String, "openai_whisper-large-v3_turbo")
        XCTAssertNil(prepared["secret"])
    }
}
