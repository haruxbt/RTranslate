import Foundation
import WebinarCore
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertFalse(_ value: Bool) { precondition(!value) }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b) }
@main struct PipelineTests {
    static func main() {
        let checks = PipelineTests()
        checks.testAudioIdentityPreservesRepeatedSpeech()
        checks.testSeparateSentencesEmitInOrder()
        checks.testShortSentenceGrouping()
        checks.testStableSlidesOnlyOncePerChange()
        checks.testSpeechAccelerationWithoutSlowingUserChoice()
        checks.testSentenceIsNotCutAt22Words()
        checks.testConditionalContinuation()
        checks.testPauseAndDeadline()
        checks.testSnapshotAndLosslessStop()
        checks.testFillerCleanupPreservesMeaning()
        checks.testScopedDictionaryCorrection()
        checks.testLegacyHistoryDecodes()
        checks.testJapanesePolish()
        checks.testHistoryCalendarExpiration()
        checks.testLegacyHistoryMigrationIsStable()
        checks.testHistoryRetentionRoundTrip()
        checks.testBrowserPauseWatchdog()
        checks.testReadableJapanese()
        checks.testSpeechDictionary()
        checks.testGitHubReleaseUpdates()
        checks.testDictionaryRowEditing()
        checks.testPageReadingChunks()
        print("PASS: 22 pipeline checks")
    }
    func testPageReadingChunks() {
        let mixed = "OAuthを使います。 Confirm the grant before a review. 手順を確認します。"
        let chunks = PageReading.chunks(mixed, separateLanguages: true)
        XCTAssertEqual(chunks, ["OAuthを使います。", "Confirm the grant before a review.", "手順を確認します。"])
        XCTAssertEqual(chunks.filter(PageReading.needsEnglishTranslation), ["Confirm the grant before a review."])
        let long = Array(repeating: "words", count: 300).joined(separator: " ")
        let pieces = PageReading.chunks(long)
        XCTAssertEqual(pieces.joined(separator: " "), long)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 420 })
        XCTAssertTrue(PageReading.containsUntranslatedProse("設定を確認。 Review the settings before enabling this option."))
        XCTAssertFalse(PageReading.containsUntranslatedProse("OpenAI APIを使用します。"))
    }
    func testBrowserPauseWatchdog() {
        var watch = BrowserInputWatchdog(now: 0)
        XCTAssertFalse(watch.timedOut(at: 89)); XCTAssertTrue(watch.timedOut(at: 91))
        watch.heartbeat(paused: true, at: 1)
        for now in stride(from: 3.0, through: 201.0, by: 2) {
            watch.heartbeat(paused: true, at: now); XCTAssertFalse(watch.timedOut(at: now + 1))
        }
        XCTAssertTrue(watch.timedOut(at: 214)) // vanished paused tab still times out
        watch.packet(at: 202); watch.heartbeat(paused: false, at: 203)
        XCTAssertFalse(watch.timedOut(at: 204))
        watch.heartbeat(paused: false, at: 214)
        XCTAssertTrue(watch.timedOut(at: 216)) // heartbeats cannot hide missing playing PCM
        watch.heartbeat(paused: true, at: 217); watch.heartbeat(paused: false, at: 500)
        XCTAssertFalse(watch.timedOut(at: 501)) // resume gets fresh packet deadline
        watch.packet(at: 502); XCTAssertFalse(watch.timedOut(at: 503))
    }
    func testAudioIdentityPreservesRepeatedSpeech() {
        var gate = FinalRangeGate()
        XCTAssertTrue(gate.accept(start: 0, duration: 2))
        XCTAssertFalse(gate.accept(start: 0, duration: 2))
        XCTAssertFalse(gate.accept(start: 1, duration: 2))
        XCTAssertTrue(gate.accept(start: 2, duration: 2))
        XCTAssertFalse(gate.accept(start: .nan, duration: 1))
    }
    func testSeparateSentencesEmitInOrder() {
        var assembler = ListeningAssembler()
        XCTAssertEqual(assembler.append("No.", audioEnd: 1, at: 2).count, 0)
        let first = assembler.append("MFA is required.", audioEnd: 3, at: 4)
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(assembler.poll(at: 6).isEmpty)
        XCTAssertEqual(assembler.poll(at: 8).map(\.english), ["No. MFA is required."])
    }
    func testStableSlidesOnlyOncePerChange() {
        var gate = SlideStability()
        XCTAssertFalse(gate.observe([0, 0]))
        XCTAssertFalse(gate.observe([0, 0]))
        XCTAssertTrue(gate.observe([0, 0]))
        XCTAssertFalse(gate.observe([0, 0]))
        XCTAssertFalse(gate.observe([100, 100]))
        XCTAssertFalse(gate.observe([100, 100]))
        XCTAssertTrue(gate.observe([100, 100]))
    }
    func testSpeechAccelerationWithoutSlowingUserChoice() {
        var accelerated = false
        let short = Array(repeating: "短い文です。", count: 5).reduce(0.0) { $0 + SpeechPacing.estimatedSeconds($1, base: 1.25) }
        XCTAssertEqual(SpeechPacing.speed(base: 1.25, queuedSeconds: short, automatic: true, accelerated: &accelerated), 1.25)
        XCTAssertEqual(SpeechPacing.speed(base: 1.25, queuedSeconds: 16, automatic: true, accelerated: &accelerated), 1.5)
        XCTAssertEqual(SpeechPacing.speed(base: 1.25, queuedSeconds: 10, automatic: true, accelerated: &accelerated), 1.5)
        XCTAssertEqual(SpeechPacing.speed(base: 1.25, queuedSeconds: 7, automatic: true, accelerated: &accelerated), 1.25)
        XCTAssertEqual(SpeechPacing.speed(base: 1.75, queuedSeconds: 30, automatic: true, accelerated: &accelerated), 1.75)
        XCTAssertEqual(SpeechPacing.speed(base: 2, queuedSeconds: 30, automatic: true, accelerated: &accelerated), 2)
        XCTAssertEqual(SpeechPacing.speed(base: 1.25, queuedSeconds: 100, automatic: false, accelerated: &accelerated), 1.25)
        XCTAssertFalse(accelerated)
    }
    func testShortSentenceGrouping() {
        var assembler = ListeningAssembler()
        let fragments = ["It was not very long ago.", "So as an example, you do not need any special Google magic for this.", "Your organization can do the same.", "By combining the different data feeds.", "Most are open source, but some may also be developed in house."]
        var output: [ListeningUnit] = []
        for (i, text) in fragments.enumerated() {
            output += assembler.append(text, audioEnd: Double(i + 1), at: Double(i * 2))
            output += assembler.poll(at: Double(i * 2 + 1), partial: "next words")
        }
        output += assembler.poll(at: 12)
        XCTAssertEqual(output.map(\.english).joined(separator: " "), fragments.joined(separator: " "))
        XCTAssertTrue(output.count < fragments.count)
        XCTAssertEqual(output.first?.audioEnd, 3)
        // Continuous short sentences cannot postpone publication indefinitely.
        var continuous = ListeningAssembler()
        _ = continuous.append("Keep it safe.", audioEnd: 1, at: 0)
        _ = continuous.append("Check again.", audioEnd: 5, at: 5)
        XCTAssertTrue(continuous.poll(at: 13, partial: "and").isEmpty)
        XCTAssertEqual(continuous.poll(at: 14, partial: "and").count, 1)
    }
    func testReadableJapanese() {
        XCTAssertEqual(PronunciationText.displayed("監査を行った担当の方はSquareを確認しました。"), "監査をおこなった担当のかたはSquareを確認しました。")
        let preserved = "会場に行った。一方、方法と方向を確認する方がよい。担当の方針も変わらない。24時間は変更しない。"
        XCTAssertEqual(PronunciationText.displayed(preserved), preserved)
        XCTAssertEqual(PronunciationText.displayed("担当の方", terms: [GlossaryTerm(source: "担当の方", target: "ご担当者")]), "ご担当者")
    }
    func testSpeechDictionary() {
        let terms = [GlossaryTerm(source: "Square", target: "スクエア")]
        XCTAssertEqual(PronunciationText.replacing("SquareとSQUAREです。Squaredは保持。", terms: terms), "スクエアとスクエアです。Squaredは保持。")
        XCTAssertEqual(PronunciationText.replacing("SOC analystとSOC", terms: [GlossaryTerm(source: "SOC", target: "ソック"), GlossaryTerm(source: "SOC analyst", target: "SOC担当")]), "SOC担当とソック")
        XCTAssertEqual(PronunciationText.replacing("A", terms: [GlossaryTerm(source: "A", target: "$1")]), "$1")
    }
    func testSentenceIsNotCutAt22Words() {
        var assembler = ListeningAssembler()
        let sentence = "Do not disable multi factor authentication for any user or service account unless a documented exception has been reviewed and approved by the security operations center."
        XCTAssertEqual(assembler.append(sentence, audioEnd: 10, at: 11).count, 0)
        XCTAssertEqual(assembler.poll(at: 12).count, 0)
        let emitted = assembler.poll(at: 13)
        XCTAssertEqual(emitted.count, 1); XCTAssertEqual(emitted[0].english, sentence)
        XCTAssertEqual(assembler.poll(at: 20).count, 0)
    }
    func testConditionalContinuation() {
        var assembler = ListeningAssembler()
        _ = assembler.append("Do not grant access.", audioEnd: 1, at: 2)
        XCTAssertEqual(assembler.poll(at: 4, partial: "unless MFA").count, 0)
        XCTAssertEqual(assembler.append("unless MFA is enabled.", audioEnd: 5, at: 6).count, 0)
        let unit = assembler.poll(at: 10)[0]
        XCTAssertEqual(ListeningText.english(unit.english, smooth: true, corrections: []), "Do not grant access unless MFA is enabled.")
        var leading = ListeningAssembler()
        _ = leading.append("If MFA is disabled,", audioEnd: 1, at: 2)
        XCTAssertEqual(leading.poll(at: 7).count, 0)
        _ = leading.append("do not grant access.", audioEnd: 8, at: 9)
        XCTAssertEqual(leading.poll(at: 13)[0].english, "If MFA is disabled, do not grant access.")
    }
    func testPauseAndDeadline() {
        var assembler = ListeningAssembler()
        _ = assembler.append("We monitor threats in the SOC", audioEnd: 1, at: 2)
        XCTAssertEqual(assembler.poll(at: 5).count, 0)
        XCTAssertEqual(assembler.poll(at: 6).first?.reason, "発話の区切り")
        _ = assembler.append("Do not grant access unless", audioEnd: 10, at: 11)
        XCTAssertEqual(assembler.poll(at: 24).count, 0)
        XCTAssertEqual(assembler.poll(at: 25).first?.reason, "待ち時間上限・途中の可能性あり")
    }
    func testSnapshotAndLosslessStop() {
        var assembler = ListeningAssembler()
        _ = assembler.append("The SOC monitors", audioEnd: 1, at: 2)
        let id = assembler.snapshot!.id
        _ = assembler.append("security events", audioEnd: 3, at: 4)
        XCTAssertEqual(assembler.snapshot!.id, id)
        XCTAssertEqual(assembler.flush(reason: "停止")[0].english, "The SOC monitors security events")
        XCTAssertEqual(assembler.flush(reason: "停止").count, 0)
        let long = Array(repeating: "security", count: 450).joined(separator: " ")
        var all = assembler.append(long, audioEnd: 10, at: 11)
        all += assembler.flush(reason: "停止")
        XCTAssertEqual(all.map(\.english).joined(separator: " "), long)
        XCTAssertTrue(all.allSatisfy { $0.english.count <= 1600 })
    }
    func testFillerCleanupPreservesMeaning() {
        let original = "Um, do not disable MFA unless approval expires in 24 hours, right?"
        XCTAssertEqual(ListeningText.english(original, smooth: true, corrections: []), "do not disable MFA unless approval expires in 24 hours.")
        XCTAssertEqual(ListeningText.english("Right?", smooth: true, corrections: []), "")
        let meaningful = "No, no access is allowed. Turn right at the next door."
        XCTAssertEqual(ListeningText.english(meaningful, smooth: true, corrections: []), meaningful)
        XCTAssertEqual(ListeningText.english(original, smooth: false, corrections: []), original)
    }
    func testScopedDictionaryCorrection() {
        let entries = ListeningText.terms("Sock work = SOC work\nbad line\n<|plamo:bad = bad\nprice = $1")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(ListeningText.english("Sock work automation.", smooth: true, corrections: entries), "SOC work automation.")
        XCTAssertEqual(ListeningText.english("Sock workforce and socks work.", smooth: true, corrections: entries), "Sock workforce and socks work.")
        XCTAssertEqual(ListeningText.english("price", smooth: false, corrections: entries), "$1")
    }
    func testLegacyHistoryDecodes() {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","english":"Old history","note":"saved","finalAt":1}"#.utf8)
        let line = try! JSONDecoder().decode(TranscriptLine.self, from: data)
        XCTAssertEqual(line.english, "Old history"); XCTAssertTrue(line.translationInput == nil)
    }
    func testJapanesePolish() {
        XCTAssertEqual(ListeningText.japanese("ええと、これは本当に、本当に重要です。まあ、無効にしないでください。", smooth: true), "これは本当に重要です。無効にしないでください。")
        XCTAssertEqual(ListeningText.japanese("まあまあの結果です。24時間以内に変更しないでください。", smooth: true), "まあまあの結果です。24時間以内に変更しないでください。")
    }
    func testHistoryCalendarExpiration() {
        let iso = ISO8601DateFormatter()
        let created = iso.date(from: "2025-11-30T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var line = TranscriptLine(english: "Keep the full sentence.", audioEnd: nil, finalAt: 1)
        line.createdAt = created
        let boundary = iso.date(from: "2026-02-28T12:00:00Z")!
        XCTAssertEqual(HistoryRetention.retained([line], now: boundary.addingTimeInterval(-1), calendar: calendar).count, 1)
        XCTAssertEqual(HistoryRetention.retained([line], now: boundary, calendar: calendar).count, 0)
        // A calendar quarter is not a fixed 90-day interval (Nov 30 -> Feb 28 is 90 here).
        line.createdAt = iso.date(from: "2024-01-31T12:00:00Z")!
        let end = iso.date(from: "2024-04-30T12:00:00Z")!
        XCTAssertEqual(HistoryRetention.retained([line], now: end.addingTimeInterval(-1), calendar: calendar).count, 1)
        XCTAssertTrue(HistoryRetention.retained([line], now: end, calendar: calendar).isEmpty)
    }
    func testLegacyHistoryMigrationIsStable() {
        let raw = Data(#"{"id":"00000000-0000-0000-0000-000000000001","english":"Old history","note":"saved","finalAt":1}"#.utf8)
        let old = try! JSONDecoder().decode(TranscriptLine.self, from: raw)
        XCTAssertTrue(old.createdAt == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let migrated = HistoryRetention.retained([old], now: now)
        XCTAssertEqual(migrated[0].id, old.id); XCTAssertEqual(migrated[0].createdAt, now)
        let decoded = try! JSONDecoder().decode([TranscriptLine].self, from: JSONEncoder().encode(migrated))
        let reloaded = HistoryRetention.retained(decoded, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(reloaded[0].createdAt, now) // reopening never extends the expiry
        XCTAssertEqual(reloaded[0].english, "Old history")
    }
    func testHistoryRetentionRoundTrip() {
        let now = Date()
        var recent = TranscriptLine(english: "Do not change 24 hours.", audioEnd: 10, finalAt: 11)
        recent.createdAt = now; recent.japanese = "24時間を変更しないでください。"
        var expired = recent; expired.createdAt = Calendar.current.date(byAdding: .month, value: -4, to: now)
        let incoming = try! JSONDecoder().decode([TranscriptLine].self, from: JSONEncoder().encode([expired, recent]))
        let kept = HistoryRetention.retained(incoming, now: now)
        XCTAssertEqual(kept.count, 1); XCTAssertEqual(kept[0].japanese, recent.japanese)
        XCTAssertEqual(kept[0].audioEnd, 10); XCTAssertEqual(kept[0].createdAt, recent.createdAt)
    }

    func testGitHubReleaseUpdates() {
        let github = AppUpdateInfo(json: ["tag_name": "v0.3.10", "html_url": "https://github.com/example/app/releases/tag/v0.3.10"])!
        XCTAssertTrue(github.isNewer(than: "0.3.9")); XCTAssertFalse(github.isNewer(than: "0.3.10"))
        XCTAssertEqual(github.page?.scheme, "https")
        XCTAssertTrue(AppUpdateInfo(json: ["tag_name": "v0.4.0", "prerelease": true]) == nil)
        XCTAssertTrue(AppUpdateInfo(json: ["version": "latest"]) == nil)
        XCTAssertTrue(AppUpdateInfo(json: ["version": "1.0.0", "downloadURL": "http://example.test/file"])?.page == nil)
        XCTAssertEqual(AppUpdateInfo(json: ["version": "0.3.3"])?.version, "0.3.3")
    }

    func testDictionaryRowEditing() {
        let text = "SOC = SOC\ninvalid row kept\nSquare = スクエア"
        let added = try! DictionaryEdit.applying(to: text, original: nil, source: "MFA", target: "MFA")
        XCTAssertTrue(added.contains("invalid row kept")); XCTAssertTrue(added.contains("SOC = SOC"))
        let renamed = try! DictionaryEdit.applying(to: added, original: "SOC", source: "SIEM", target: "SIEM")
        XCTAssertFalse(renamed.contains("SOC = SOC")); XCTAssertTrue(renamed.contains("invalid row kept"))
        let removed = try! DictionaryEdit.applying(to: renamed, original: "Square", source: "", target: "", deleting: true)
        XCTAssertFalse(removed.contains("Square")); XCTAssertTrue(removed.contains("MFA = MFA"))
        XCTAssertTrue((try? DictionaryEdit.applying(to: text, original: nil, source: "bad=source", target: "value")) == nil)
        let full = (0..<100).map { "term\($0) = value" }.joined(separator: "\n")
        XCTAssertTrue((try? DictionaryEdit.applying(to: full, original: nil, source: "new", target: "value")) == nil)
        XCTAssertTrue((try? DictionaryEdit.applying(to: full, original: "term1", source: "term1", target: "updated")) != nil)
    }

}
