import XCTest
@testable import YuyinCore

final class TextAndSpeakerTests: XCTestCase {
    func testExporterSkipsEmptyAndNumbersSRTSequentially() {
        let a = Utterance(startMs: 1000, endMs: 2500, partial: "测试", finalText: "测试完成。", status: .final, provider: "x")
        let empty = Utterance(startMs: 3000, endMs: 3500, partial: "", finalText: "。", status: .final, provider: "x")
        let b = Utterance(startMs: 3_725_000, endMs: 3_726_000, partial: "第二句", status: .failed, provider: "x", speakerIndex: 1)

        XCTAssertEqual(TranscriptExporter.export([a, empty, b], format: .plainText), "测试完成。\n[说话人 2] 第二句")

        let srt = TranscriptExporter.export([b, empty, a], format: .srt)
        XCTAssertEqual(srt, """
        1
        00:00:01,000 --> 00:00:02,500
        测试完成。

        2
        01:02:05,000 --> 01:02:06,000
        [说话人 2] 第二句

        """)

        let md = TranscriptExporter.export([a, b], format: .markdown, title: "周会")
        XCTAssertTrue(md.hasPrefix("# 周会"))
        XCTAssertTrue(md.contains("- **1:02:05** · *说话人 2* — 第二句"))
    }

    func testHallucinationFilter() {
        XCTAssertTrue(TextFilter.looksHallucinated("我操，这这这这这这这这。"))
        XCTAssertTrue(TextFilter.looksHallucinated("g 零 axy x s x s y s 的这的一西"))
        XCTAssertFalse(TextFilter.looksHallucinated("怎么样才能提高高识别的效果呢？"))
        XCTAssertFalse(TextFilter.looksHallucinated("哈哈哈，好的。"))
        XCTAssertFalse(TextFilter.looksHallucinated("用 Swift 写一个 App"))
        XCTAssertFalse(TextFilter.looksHallucinated("The tribal chieftain called for the boy"))
        // Short Chinese exclamations that a multilingual model turned into Japanese.
        XCTAssertTrue(TextFilter.looksHallucinated("ちょっと。"))
        XCTAssertTrue(TextFilter.looksHallucinated("ええよっ！"))
        XCTAssertTrue(TextFilter.looksHallucinated("최초"))
        XCTAssertFalse(TextFilter.looksHallucinated("这波打过来了。"))
    }

    func testEnglishGetsASCIIPunctuation() {
        XCTAssertEqual(TextFilter.normalizePunctuation("Entrepreneur，and I also do real estate. Well，you're busy。"),
                       "Entrepreneur, and I also do real estate. Well, you're busy.")
        XCTAssertEqual(TextFilter.normalizePunctuation("我们用 Swift，写一个 App。"), "我们用 Swift，写一个 App。")
    }

    func testShortClipsDontCreateSpeakers() {
        var c = OnlineSpeakerClusterer()
        XCTAssertEqual(c.assign([1, 0, 0], speechMs: 500), 0, "the very first clip always starts speaker 1")
        // Noisy short clip of the same person (similarity 0.4) joins instead of splitting.
        XCTAssertEqual(c.assign([0.4, 0.92, 0], speechMs: 400), 0)
        // A short clip unlike anyone (0.3) stays unknown rather than being pinned on speaker 1.
        XCTAssertNil(c.assign([0.3, 0, 0.954], speechMs: 400))
        XCTAssertNil(c.assign([0, 0, 1], speechMs: 300))
        // A confident long clip of someone else starts speaker 2.
        XCTAssertEqual(c.assign([0, 0, 1], speechMs: 2000), 1)
        XCTAssertEqual(c.speakerCount, 2)
    }

    /// The same person's 2 s sentences rarely reach the full threshold; long ones must.
    func testShortClipsJoinAtALowerSimilarity() {
        var c = OnlineSpeakerClusterer()
        XCTAssertEqual(c.joinThreshold(speechMs: 6000), 0.5, accuracy: 0.001)
        XCTAssertEqual(c.joinThreshold(speechMs: 2000), 0.4, accuracy: 0.001)
        XCTAssertEqual(c.assign([1, 0, 0], speechMs: 5000), 0)
        XCTAssertEqual(c.assign([0.45, 0.893, 0], speechMs: 2000), 0, "2 s clip at 0.45 joins")
        var d = OnlineSpeakerClusterer()
        _ = d.assign([1, 0, 0], speechMs: 5000)
        XCTAssertEqual(d.assign([0.45, 0.893, 0], speechMs: 5000), 1, "5 s clip at 0.45 is someone else")
    }

    func testNormalizationRaisesQuietSpeechWithoutClipping() {
        let quiet = Signal.speech(ms: 1000, amplitude: 0.02)
        let loud = AudioSpec.normalizedForRecognition(quiet)
        XCTAssertGreaterThan(AudioSpec.peak(loud), AudioSpec.peak(quiet) * 3)
        XCTAssertLessThanOrEqual(AudioSpec.peak(loud), 0.95 + 1e-4)
        let normal = Signal.speech(ms: 1000, amplitude: 0.3)
        XCTAssertEqual(AudioSpec.normalizedForRecognition(normal), normal, "already loud speech is left alone")
    }

    func testCaseNormalizationAndContentUnits() {
        XCTAssertEqual(TextFilter.normalizeCase("YOUR JOB OH MY GOD I GROWING IT"), "Your job oh my god I growing it")
        XCTAssertEqual(TextFilter.normalizeCase("THIS ENTIRE MEETING. TELL US YOUR NAME"), "This entire meeting. Tell us your name")
        XCTAssertEqual(TextFilter.normalizeCase("苹果全新的 HomePod 呀"), "苹果全新的 HomePod 呀")
        XCTAssertEqual(TextFilter.normalizeCase("我们用 API"), "我们用 API", "short acronyms stay")
        XCTAssertEqual(TextFilter.contentUnits("哎，没布为什么要 iPhone 15"), 9)
    }

    func testTextFilter() {
        XCTAssertFalse(TextFilter.isMeaningful(""))
        XCTAssertFalse(TextFilter.isMeaningful("。，！ "))
        XCTAssertTrue(TextFilter.isMeaningful("好。"))
        XCTAssertTrue(TextFilter.isMeaningful("ok"))
    }

    func testClustererSeparatesSpeakersAndRespectsCap() {
        var c = OnlineSpeakerClusterer(threshold: 0.6)
        XCTAssertEqual(c.assign([1, 0, 0]), 0)
        XCTAssertEqual(c.assign([0.9, 0.1, 0]), 0)
        XCTAssertEqual(c.assign([0, 1, 0]), 1)
        XCTAssertEqual(c.assign([0, 0, 1]), 2)
        XCTAssertNil(c.assign([0, 0, 0]))

        var capped = OnlineSpeakerClusterer(threshold: 0.9, maxSpeakers: 2)
        _ = capped.assign([1, 0])
        _ = capped.assign([0, 1])
        XCTAssertEqual(capped.assign([0.6, 0.8]), 1)
        XCTAssertEqual(capped.speakerCount, 2)
    }

    func testSpeakerMappingRenumbersByFirstAppearance() {
        let u1 = Utterance(startMs: 0, endMs: 1000, provider: "x")
        let u2 = Utterance(startMs: 1200, endMs: 2000, provider: "x")
        let u3 = Utterance(startMs: 9000, endMs: 9500, provider: "x")
        let segments = [
            SpeakerSegment(startMs: 0, endMs: 1100, speakerIndex: 3),
            SpeakerSegment(startMs: 1100, endMs: 2100, speakerIndex: 0),
        ]
        let map = SpeakerMapping.map([u3, u2, u1], segments: segments)
        XCTAssertEqual(map[u1.id], .some(0))
        XCTAssertEqual(map[u2.id], .some(1))
        XCTAssertEqual(map[u3.id], .some(nil))
    }
}

final class ChineseSpacingTests: XCTestCase {
    func testSpacesNextToChineseGoButLatinWordsKeepTheirs() {
        XCTAssertEqual(TextFilter.tightenChineseSpacing("首期款， 通过承租 公交的方式"), "首期款，通过承租公交的方式")
        XCTAssertEqual(TextFilter.tightenChineseSpacing("我们用 Fun ASR 来转写"), "我们用Fun ASR来转写")
        XCTAssertEqual(TextFilter.tightenChineseSpacing("Let's sync again."), "Let's sync again.")
    }
}

final class TermLexiconTests: XCTestCase {
    /// Real errors from the user's case discussion.
    func testLegalTermsReplaceSameSoundingWords() {
        let lexicon = TermLexicon(terms: LegalVocabulary.terms)
        XCTAssertEqual(lexicon.correct("纯粹是为了影响法官的新政。"), "纯粹是为了影响法官的心证。")
        XCTAssertEqual(lexicon.correct("这个设备本身存在权力瑕疵"), "这个设备本身存在权利瑕疵")
        XCTAssertEqual(lexicon.correct("就是诉讼旅行的问题"), "就是诉讼履行的问题")
    }

    func testDifferentTonesAndAmbiguousWordsStay() {
        let lexicon = TermLexicon(terms: LegalVocabulary.terms)
        // 语气 yǔqì ≠ 逾期 yúqī; 权力 and 定金 / 订金 are law terms of their own.
        for text in ["我解除函只说了语气", "公权力的边界", "先付了订金", "我们才定下来", "现在甚至证据都没有"] {
            XCTAssertEqual(lexicon.correct(text), text)
        }
    }

    func testUserTermsWithLatinLettersAreIgnoredAndOthersApply() {
        let settings = AppSettings(legalTerms: false, vocabulary: ["长城汽车", "ABC公司", " "])
        let lexicon = settings.termLexicon
        XCTAssertEqual(lexicon.correct("我们一直和长成汽车合作"), "我们一直和长城汽车合作")
        XCTAssertEqual(lexicon.correct("影响法官的新政"), "影响法官的新政", "legal terms are off")
    }

    /// Sounds alike but not the same: only long terms, ≥ 75% alike, on word boundaries.
    func testSimilarSoundingLongTermsAreCorrected() {
        let lexicon = TermLexicon(names: ["成都航天", "王海林", "徐律师", "作业指导书"])
        // 行间 xíngjiān / 航天 hángtiān.
        XCTAssertEqual(lexicon.correct("就是以成都行间的这些专利"), "就是以成都航天的这些专利")
        // 宁 níng / 林 lín: a near miss.
        XCTAssertEqual(lexicon.correct("刚才王海宁说"), "刚才王海林说")
        // Other lawyers in the meeting: a different surname is not a near miss.
        XCTAssertEqual(lexicon.correct("我跟那个王律师讨论过石律师的逻辑"), "我跟那个王律师讨论过石律师的逻辑")
        // Nothing alike enough: left alone.
        XCTAssertEqual(lexicon.correct("物业制造书"), "物业制造书")
    }

    func testTwoCharacterTermsNeedTheSameSound() {
        let lexicon = TermLexicon(terms: LegalVocabulary.terms)
        // 指正 zhǐzhèng is one tone away from 质证 zhìzhèng.
        XCTAssertEqual(lexicon.correct("请大家批评指正"), "请大家批评指正")
    }

    /// Built-in terms begin with everyday words; similar sound would rewrite those (seen on the
    /// user's meeting), so they need the same sound.
    func testBuiltInTermsNeverMatchBySimilarSound() {
        let lexicon = TermLexicon(terms: LegalVocabulary.terms)
        for text in ["这是买卖合同中呢", "他意思就是说我们", "最后一份证据目的是什么", "格鲁伯斯基表示说"] {
            XCTAssertEqual(lexicon.correct(text), text)
        }
        // Not even as a 3-character name: 中 zhōng / 编 biān is more than a near miss.
        XCTAssertEqual(TermLexicon(names: ["合同编"]).correct("这是买卖合同中呢"), "这是买卖合同中呢")
        // A character off in initial, final and tone is never a near miss.
        XCTAssertEqual(TermLexicon(names: ["长城汽车"]).correct("长城的车"), "长城的车")
    }

    func testRulesReplaceExactlyAndBecomeHotwords() {
        let lexicon = TermLexicon(names: ["备诉=反诉", "物业制造书 → 作业指导书", "长城汽车", "a=a"])
        XCTAssertEqual(lexicon.correct("他提了一个备诉，说物业制造书有问题"), "他提了一个反诉，说作业指导书有问题")
        XCTAssertEqual(lexicon.hotwords, ["反诉", "作业指导书", "长城汽车"])
    }

    func testPinyinIsSplitIntoInitialFinalAndTone() {
        XCTAssertEqual(Syllable.parse("zhèng"), Syllable(initial: "zh", final: "eng", tone: 4))
        XCTAssertEqual(Syllable.parse("lǜ"), Syllable(initial: "l", final: "v", tone: 4))
        XCTAssertEqual(Syllable.parse("yǔ"), Syllable(initial: "y", final: "v", tone: 3))
        XCTAssertEqual(Syllable.parse("ér"), Syllable(initial: "", final: "er", tone: 2))
        XCTAssertEqual(Syllable.parse("de"), Syllable(initial: "d", final: "e", tone: 5))
    }

    func testSettingsRoundTripKeepsVocabulary() throws {
        let settings = AppSettings(legalTerms: false, vocabulary: ["成都航天"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.vocabulary, ["成都航天"])
        XCTAssertFalse(decoded.legalTerms)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).legalTerms)
    }
}

final class VocabularyTests: XCTestCase {
    func testParsingSplitsOnChineseAndLatinSeparatorsAndDropsDuplicates() {
        XCTAssertEqual(AppSettings.parseVocabulary("长城汽车，成都航天、 徐律师\n长城汽车;ABC"), ["长城汽车", "成都航天", "徐律师", "ABC"])
        XCTAssertEqual(AppSettings.parseVocabulary(" ，\n "), [])
    }

    func testHotwordsStayWithinTheLLMPromptBudget() {
        let settings = AppSettings(vocabulary: (1...40).map { "名词\($0)" })
        XCTAssertEqual(settings.hotwords.split(separator: ",").count, 20)
    }
}

final class EarlyCorrectionJoinTests: XCTestCase {
    /// Seen while replaying the user's monologue.
    func testRepeatedWordsAndTheFullStopAtTheJoinGo() {
        XCTAssertEqual(TextFilter.joinCorrected("但是呢，他们在自己。", live: "在自己生产的过程中"),
                       "但是呢，他们在自己生产的过程中")
        XCTAssertEqual(TextFilter.joinCorrected("什么西门子啊，什么这种业内。", live: "么这种业内顶级的专家"),
                       "什么西门子啊，什么这种业内顶级的专家")
        XCTAssertEqual(TextFilter.joinCorrected("是为了是证明什么呢？", live: "呢？我们给你"), "是为了是证明什么呢？我们给你")
    }

    func testWithoutOverlapTheLiveTextFollows() {
        XCTAssertEqual(TextFilter.joinCorrected("合同是这个内容", live: "第八个是什么"), "合同是这个内容第八个是什么")
        XCTAssertEqual(TextFilter.joinCorrected("合同是这个内容，", live: "第八个"), "合同是这个内容，第八个")
        XCTAssertEqual(TextFilter.joinCorrected("就是这样。", live: ""), "就是这样")
    }
}

final class RelevantTermsTests: XCTestCase {
    func testTermsAreFoundBySoundInTheLiveText() {
        let lexicon = TermLexicon(terms: LegalVocabulary.terms, names: ["作业指导书", "成都航天"])
        // Live text as X-ASR wrote it in the user's meeting.
        let terms = lexicon.relevantTerms(in: "我们提供给他的物业制造书，成都行间提了一个备诉")
        XCTAssertTrue(terms.contains("作业指导书"), "\(terms)")
        XCTAssertTrue(terms.contains("成都航天"), "\(terms)")
        XCTAssertLessThanOrEqual(terms.count, 20)
        XCTAssertFalse(terms.contains("取保候审"), "nothing like it was said: \(terms)")
    }

    func testExactMentionsComeFirst() {
        let lexicon = TermLexicon(terms: LegalVocabulary.terms)
        XCTAssertEqual(lexicon.relevantTerms(in: "这个案件的诉讼时效已经过了", limit: 1), ["诉讼时效"])
    }
}

final class RepetitionLoopTests: XCTestCase {
    /// Qwen3-ASR outputs on the user's meeting.
    func testLoopsAreFoundAndCollapsed() {
        let loop = "但是我的理解，它重要的在于我要表示我要解除。除非是你当时你的。除非是你当时你的。除非是你当时你的。除非是你当时你的。"
        XCTAssertNotNil(TextFilter.repetitionLoop(loop))
        XCTAssertEqual(TextFilter.collapsingRepetition(loop), "但是我的理解，它重要的在于我要表示我要解除。除非是你当时你的。")

        let twice = "我不说，我就说我要解除。那你这个解除有效吗？我不说，我就说我要解除。那你这个解除有效吗？"
        XCTAssertNotNil(TextFilter.repetitionLoop(twice))
        XCTAssertEqual(TextFilter.collapsingRepetition(twice), "我不说，我就说我要解除。那你这个解除有效吗？")
    }

    func testALongStretchSaidTwiceWithWordsBetweenIsALoop() {
        let text = "你你提的是迟延，法官不会说，哎，这好像是质量瑕疵。那太多了，审不完。你你提的是迟延，法官不会说，哎，这好像是质量瑕"
        XCTAssertNotNil(TextFilter.repetitionLoop(text))
    }

    func testRealSpeechRepetitionIsNotALoop() {
        for text in ["我我我到底做错了啥？对对对对对。", "这个这个第八个是我们呃沟通过程中", "你提的解除，你提的解除，你要把事由讲清楚。",
                     "原封原封不动的给了你", "是是是，就只能变成这样"] {
            XCTAssertNil(TextFilter.repetitionLoop(text), text)
        }
    }
}

final class PolishTests: XCTestCase {
    func testAnswersMustLineUpWithTheParagraphs() {
        XCTAssertEqual(TranscriptPolish.parse("【1】作业指导书是长城汽车给我们的。\n\n【2】徐律师：对。", count: 2),
                       ["作业指导书是长城汽车给我们的。", "对。"])
        XCTAssertEqual(TranscriptPolish.parse("好的：\n【1】甲，乙。【2】丙。", count: 2), ["甲，乙。", "丙。"])
        XCTAssertNil(TranscriptPolish.parse("【1】甲乙丙", count: 2), "a paragraph left out")
        XCTAssertNil(TranscriptPolish.parse("【2】乙\n【1】甲", count: 2), "out of order")
    }

    /// Seen with Qwen3-4B on the user's meeting: a light cleanup passes, a summary does not.
    func testRewritesThatSummarizeOrInventAreRejected() {
        let original = "但是呢他们在自己生产的过程中，包括提到了很多业内的专。加什么西门子啊，什么这种业内顶级的专家发现这个零部件不可能做到圆柱状。"
        XCTAssertTrue(TranscriptPolish.isFaithful("但是他们在自己生产的过程中，请教了很多业内的专家，比如西门子等业内顶级的专家，发现这个零部件不可能做到圆柱状。", to: original))
        XCTAssertFalse(TranscriptPolish.isFaithful("所以我们为了影响法官的判断，提前准备了上述证据链。", to: original))
        XCTAssertFalse(TranscriptPolish.isFaithful("专家认为无法加工。", to: original), "most of what was said is gone")
    }

    func testRuleCleanupRemovesOnlyFillers() {
        XCTAssertEqual(TextFilter.removingFillers("我就是一个代理人，嗯，那代理人会有必要的义务。呃。这个这个这个这个。"),
                       "我就是一个代理人，那代理人会有必要的义务。这个。")
        XCTAssertEqual(TextFilter.removingFillers("我我我到底做错了啥"), "我到底做错了啥")
        XCTAssertEqual(TextFilter.removingFillers("常常看看，一个一个来"), "常常看看，一个一个来")
    }

    func testTurnsGroupOneSpeakersSentences() {
        let us = [Utterance(startMs: 0, finalText: "但是呢他们包括提到了很多业内的专。", status: .final, provider: "x", speakerIndex: 0),
                  Utterance(startMs: 1, finalText: "加什么西门子啊。", status: .final, provider: "x", speakerIndex: 0),
                  Utterance(startMs: 2, finalText: "。", status: .final, provider: "x"),
                  Utterance(startMs: 3, finalText: "对。", status: .final, provider: "x", speakerIndex: 1)]
        let paragraphs = TranscriptPolish.paragraphs(us, book: SpeakerBook())
        XCTAssertEqual(paragraphs.map(\.ids.count), [2, 1])
        XCTAssertEqual(paragraphs[0].text, "但是呢他们包括提到了很多业内的专。加什么西门子啊。")
        XCTAssertEqual(paragraphs[1].speaker, "说话人 2")
    }

    /// Answers like an LLM would: once out of line, then each paragraph without its fillers.
    final class FakeModel: TextGenerating, @unchecked Sendable {
        var calls = 0
        func prepare() async throws {}
        func complete(system: String, user: String, maxTokens: Int) async throws -> String {
            calls += 1
            if calls == 1 { return "乱了" }
            return user.components(separatedBy: "\n\n").filter { $0.hasPrefix("【") }.map { block in
                let label = block[..<block.index(after: block.firstIndex(of: "】")!)]
                let text = block[block.index(after: block.firstIndex(of: "：")!)...]
                return label + text.replacingOccurrences(of: "呃，", with: "")
            }.joined(separator: "\n")
        }
        func shutdown() async {}
    }

    func testRunRetriesAMisalignedAnswerAndPutsTheTurnOnItsFirstSentence() async throws {
        let a = Utterance(startMs: 0, finalText: "呃，这个合同是这个", status: .final, provider: "x", speakerIndex: 0)
        let b = Utterance(startMs: 1, finalText: "内容。", status: .final, provider: "x", speakerIndex: 0)
        let c = Utterance(startMs: 2, finalText: "第八个是什么？", status: .final, provider: "x", speakerIndex: 1)
        let model = FakeModel()
        let result = try await TranscriptPolish.run([a, b, c], book: SpeakerBook(), model: model, background: nil, terms: []) { _ in }
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(result[a.id], "这个合同是这个内容。")
        XCTAssertEqual(result[b.id], "")
        XCTAssertEqual(result[c.id], "第八个是什么？")
    }
}
