import XCTest
@testable import Yapper

@MainActor
final class CorrectionLearnerTests: XCTestCase {
    func testLearnsAFixedName() {
        XCTAssertEqual(CorrectionLearner.learnedWords(
            original: "Can you send the notes to shree ya before lunch?",
            edited: "Can you send the notes to Shreya before lunch?"), ["Shreya"])
        XCTAssertEqual(CorrectionLearner.learnedWords(
            original: "We deploy it with cube flow every week.",
            edited: "We deploy it with Kubeflow every week."), ["Kubeflow"])
    }

    func testIgnoresCommonWordSwapsAndUnrelatedRewrites() {
        XCTAssertEqual(CorrectionLearner.learnedWords(
            original: "I left it over their by the door",
            edited: "I left it over there by the door"), [])
        XCTAssertEqual(CorrectionLearner.learnedWords(
            original: "Meet the team at the cafe on Monday",
            edited: "Meet the team at the Stripe on Monday"), [], "unlike words are a different idea, not a mishearing")
    }

    func testIgnoresAWholeRewrite() {
        XCTAssertEqual(CorrectionLearner.learnedWords(
            original: "send it to anya tomorrow morning please",
            edited: "Actually I will call Anja tonight instead"), [])
    }

    func testLearnsAMultiWordNameAndDeduplicates() {
        XCTAssertEqual(CorrectionLearner.learnedWords(
            original: "please send the deck to shaw hun hard before the meeting, cc shaw hun hard",
            edited: "please send the deck to Shawn Hart before the meeting, cc Shawn Hart"), ["Shawn Hart"])
    }

    func testDiffFindsReplacedRunsCaseInsensitively() {
        let a = CorrectionLearner.tokens("The quick brown fox, jumps.")
        let b = CorrectionLearner.tokens("the quick Braun fox jumps high")
        XCTAssertEqual(CorrectionLearner.substitutions(a, b), [
            .init(heard: ["brown"], fixed: ["Braun"]), .init(heard: [], fixed: ["high"]),
        ])
        XCTAssertEqual(CorrectionLearner.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(CorrectionLearner.editDistance("", "abc"), 3)
    }

    func testInsertedTextTracksEditsBetweenTheSurroundingText() {
        XCTAssertEqual(CorrectionWatcher.insertedText(in: "Hi Shreya, see you", prefix: "Hi ", suffix: ", see you"), "Shreya")
        XCTAssertNil(CorrectionWatcher.insertedText(in: "Different field", prefix: "Hi ", suffix: ", see you"))
        XCTAssertNil(CorrectionWatcher.insertedText(in: "ab", prefix: "ab", suffix: "b"))
    }

    func testLearnedWordsAppendToPreferredWordsAndRespectTheCap() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CorrectionLearnerTests"))
        defaults.removePersistentDomain(forName: "CorrectionLearnerTests")
        defer { defaults.removePersistentDomain(forName: "CorrectionLearnerTests") }
        defaults.set("Yapper\n", forKey: DictationPreferences.preferredWordsKey)

        final class Box: @unchecked Sendable { var last: [AnyHashable: Any]? }
        let posted = Box()
        let observer = NotificationCenter.default.addObserver(forName: .yapperLearnedWords, object: nil, queue: nil) {
            posted.last = $0.userInfo
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        CorrectionWatcher.learn(original: "ask shree ya about it", edited: "ask Shreya about it", defaults: defaults)
        XCTAssertEqual(DictationPreferences.words(defaults), ["Yapper", "Shreya"])
        XCTAssertEqual(defaults.stringArray(forKey: DictationPreferences.recentlyLearnedKey), ["Shreya"])
        XCTAssertEqual(posted.last?["words"] as? [String], ["Shreya"])
        XCTAssertEqual(posted.last?["full"] as? Bool, false)

        defaults.set((1...50).map { "Word\($0)" }.joined(separator: "\n"), forKey: DictationPreferences.preferredWordsKey)
        CorrectionWatcher.learn(original: "ask cube flow about it", edited: "ask Kubeflow about it", defaults: defaults)
        XCTAssertEqual(DictationPreferences.words(defaults).count, 50)
        XCTAssertFalse(DictationPreferences.words(defaults).contains("Kubeflow"))
        XCTAssertEqual(posted.last?["words"] as? [String], ["Kubeflow"])
        XCTAssertEqual(posted.last?["full"] as? Bool, true)
    }
}
