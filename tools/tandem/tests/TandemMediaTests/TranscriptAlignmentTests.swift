import TandemCore
import XCTest
@testable import TandemMedia

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: text, start: Time(seconds: start), end: Time(seconds: end))
}

/// A waveform at 100 peaks a second: the room at `floor` dB except where
/// `voice` says, as (start, end, level in dB).
private func waveform(length: Double, voice: [(start: Double, end: Double, level: Double)], floor: Double = -60) -> Waveform {
    let count = Int((length * 100).rounded())
    var peaks = [Float](repeating: Float(pow(10, floor / 20)), count: count)
    for span in voice {
        for index in Int((span.start * 100).rounded())..<min(count, Int((span.end * 100).rounded())) {
            peaks[index] = Float(pow(10, span.level / 20))
        }
    }
    return Waveform(samplesPerSecond: 100, peaks: peaks)
}

private func assertTimes(_ word: TranscriptWord, _ start: Double, _ end: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(word.start.seconds, start, accuracy: 0.001, "\(word.text) start", file: file, line: line)
    XCTAssertEqual(word.end.seconds, end, accuracy: 0.001, "\(word.text) end", file: file, line: line)
}

final class TranscriptAlignmentTests: XCTestCase {
    func testAWordStretchedOverSilenceIsTrimmedToTheVoice() {
        // Voice 1-2 s and 3-4 s; the engine ran "one" on to 2.9.
        let wave = waveform(length: 5, voice: [(1, 2, -15), (3, 4, -15)])
        let aligned = TranscriptAlignment.align([word("one", 1, 2.9), word("two", 2.9, 4)], waveform: wave)
        assertTimes(aligned[0], 1, 2)
        assertTimes(aligned[1], 3, 4)
        let pauses = Transcript(language: "en-US", engine: "test", words: aligned).pauses(longerThan: Time(seconds: 0.5))
        XCTAssertEqual(pauses, [TimeRange(start: Time(seconds: 2), end: Time(seconds: 3))])
    }

    func testAWordThatStartsInTheSilenceMovesToTheVoice() {
        let wave = waveform(length: 5, voice: [(1, 2, -15), (3, 4, -15)])
        let aligned = TranscriptAlignment.align([word("one", 1, 2.1), word("two", 2.1, 4)], waveform: wave)
        assertTimes(aligned[0], 1, 2)
        assertTimes(aligned[1], 3, 4)
    }

    /// The numbers from the workbench short's phone take: "of" ran from
    /// 28.14 to 29.22 over a silence from 28.26 to 29.05, and "and" from
    /// 30.18 to 31.50 over a silence from 30.74 to 31.40.
    func testTheWorkbenchTakesOfAndAnd() {
        let wave = waveform(length: 32.5, voice: [(27.66, 28.26, -12), (29.05, 30.74, -12), (31.40, 31.68, -12)])
        let raw = [
            word("workbench", 27.66, 28.14), word("of", 28.14, 29.22), word("this", 29.22, 29.40),
            word("size", 29.40, 30.18), word("and", 30.18, 31.50), word("then", 31.50, 31.68)
        ]
        let aligned = TranscriptAlignment.align(raw, waveform: wave)
        XCTAssertEqual(aligned.map(\.text), raw.map(\.text))
        // "of" had more voice after the silence than before it, so it goes
        // there; "and" had more before.
        assertTimes(aligned[0], 27.66, 28.26)
        assertTimes(aligned[1], 29.05, 29.22)
        assertTimes(aligned[4], 30.18, 30.74)
        assertTimes(aligned[5], 31.40, 31.68)
        let pauses = Transcript(language: "en-US", engine: "test", words: aligned).pauses(longerThan: Time(seconds: 0.45))
        XCTAssertEqual(pauses.map { $0.start.seconds }, [28.26, 30.74], accuracy: 0.001)
        XCTAssertEqual(pauses.map { $0.end.seconds }, [29.05, 31.40], accuracy: 0.001)
        let before = Transcript(language: "en-US", engine: "test", words: raw).pauses(longerThan: Time(seconds: 0.45))
        XCTAssertTrue(before.isEmpty, "the engine's own times hide both pauses")
    }

    func testTheFirstWordOfATakeMovesOutOfTheLeadIn() {
        // SpeechAnalyzer put "Hi" in the silence before anything was said.
        let wave = waveform(length: 2, voice: [(0.55, 1.02, -10)])
        let aligned = TranscriptAlignment.align([word("Hi", 0, 0.54), word("guys,", 0.54, 1.08)], waveform: wave)
        XCTAssertEqual(aligned[0].start.seconds, 0.55, accuracy: 0.001)
        XCTAssertGreaterThan(aligned[0].end, aligned[0].start)
        XCTAssertEqual(aligned[1].start, aligned[0].end)
        XCTAssertEqual(aligned[1].end.seconds, 1.02, accuracy: 0.001)
    }

    func testAfterASentenceTheNextWordGoesPastThePause() {
        // From the same take: "He'd" ran over the silence after "worked.",
        // with a little more of its range before the silence than after.
        let wave = waveform(length: 51, voice: [(48.85, 49.45, -12), (49.71, 49.96, -12)])
        let sentence = TranscriptAlignment.align([word("worked.", 48.90, 49.14), word("He'd", 49.20, 49.86), word("like,", 49.86, 50.00)], waveform: wave)
        assertTimes(sentence[0], 48.85, 49.45)
        assertTimes(sentence[1], 49.71, 49.86)
        assertTimes(sentence[2], 49.86, 49.96)
        // Mid-sentence the word stays with the voice it overlaps most.
        let phrase = TranscriptAlignment.align([word("worked", 48.90, 49.14), word("He'd", 49.20, 49.86), word("like,", 49.86, 50.00)], waveform: wave)
        assertTimes(phrase[1], 49.17, 49.45)
        assertTimes(phrase[2], 49.71, 49.96)
    }

    func testBreathsAndClicksBetweenWordsStayInThePause() {
        // A 90 ms breath and a 20 ms click in the gap before "Just".
        let wave = waveform(length: 3, voice: [(0.5, 1.0, -12), (1.40, 1.49, -30), (1.80, 1.82, -8), (2.2, 2.5, -12)])
        let aligned = TranscriptAlignment.align([word("start.", 0.5, 1.3), word("Just", 1.3, 2.5)], waveform: wave)
        assertTimes(aligned[0], 0.5, 1.0)
        assertTimes(aligned[1], 2.2, 2.5)
    }

    func testVoiceRunsIgnoreClicksAndFlicker() {
        let rate = 100.0
        var levels = [Double](repeating: -60, count: 300)
        for index in 50..<100 where index % 3 != 1 { levels[index] = -20 }  // speech flickering round the threshold
        for index in 150..<152 { levels[index] = -5 }  // a click
        for index in 200..<260 { levels[index] = -20 }
        for index in 265..<280 { levels[index] = -20 }  // 50 ms apart: the same run
        let runs = TranscriptAlignment.voicedRuns(levels, rate: rate, threshold: -40, origin: 10)
        XCTAssertEqual(runs, [TranscriptAlignment.Run(start: 10.5, end: 11), TranscriptAlignment.Run(start: 12, end: 12.8)])
    }

    func testTheThresholdSitsOverTheRoom() {
        let room = [Double](repeating: -45, count: 300) + [Double](repeating: -10, count: 700)
        XCTAssertEqual(TranscriptAlignment.threshold(room), -35, accuracy: 0.001)
        // Digital silence doesn't drag it down to nothing.
        let digital = [Double](repeating: -120, count: 300) + [Double](repeating: -10, count: 700)
        XCTAssertEqual(TranscriptAlignment.threshold(digital), -40, accuracy: 0.001)
    }

    func testWordsKeepTheirTimesWithoutAUsableWaveform() {
        let words = [word("one", 1, 2.9), word("two", 2.9, 4)]
        let coarse = Waveform(samplesPerSecond: 10, peaks: [Float](repeating: 0.5, count: 50))
        XCTAssertEqual(TranscriptAlignment.align(words, waveform: coarse), words)
        // A level that never changes has no silence to find.
        let steady = waveform(length: 5, voice: [(0, 5, -12)])
        XCTAssertEqual(TranscriptAlignment.align(words, waveform: steady), words)
        // A word far from any voice keeps its own times.
        let far = TranscriptAlignment.align([word("one", 1, 1.5), word("lost", 20, 20.4)], waveform: waveform(length: 30, voice: [(1, 1.5, -12)]))
        assertTimes(far[1], 20, 20.4)
    }

    func testAShortRunSharesItsTimeByLetters() {
        let wave = waveform(length: 2, voice: [(1, 1.08, -12)])
        let aligned = TranscriptAlignment.align([word("I", 0.5, 0.9), word("wonder", 0.9, 1.5)], waveform: wave)
        assertTimes(aligned[0], 1, 1 + 0.08 / 7)
        assertTimes(aligned[1], 1 + 0.08 / 7, 1.08)
    }
}

private func placed(_ transcript: Transcript, _ clips: [Clip]) -> [(text: String, clip: String, start: Double, end: Double)] {
    transcript.placements(on: clips).map { (transcript.words[$0.index].text, $0.clipID, $0.start.seconds, $0.end.seconds) }
}

private func clip(_ id: String, at start: Double, playing from: Double, _ to: Double, speed: Double = 1) -> Clip {
    Clip(id: id, content: .media(mediaID: "med_take"), start: Time(seconds: start), duration: Time(seconds: (to - from) / speed), sourceStart: Time(seconds: from), speed: speed)
}

final class WordPlacementTests: XCTestCase {
    func testAWordACutRunsThroughPlaysOnceOnTheSideWithMostOfIt() {
        let transcript = Transcript(language: "en", engine: "test", words: [word("more", 9, 10), word("less", 10, 11)])
        // A cut from 9.7 to 10.3: "more" keeps 0.7 before it, "less" 0.7 after.
        let words = placed(transcript, [clip("clip_a", at: 0, playing: 5, 9.7), clip("clip_b", at: 4.7, playing: 10.3, 15)])
        XCTAssertEqual(words.map(\.text), ["more", "less"])
        XCTAssertEqual(words.map(\.clip), ["clip_a", "clip_b"])
        XCTAssertEqual(words[0].start, 4, accuracy: 0.001)
        XCTAssertEqual(words[0].end, 4.7, accuracy: 0.001, "clamped to its clip")
        XCTAssertEqual(words[1].start, 4.7, accuracy: 0.001)
        XCTAssertEqual(words[1].end, 5.4, accuracy: 0.001)
        // Split exactly through the middle, the earlier clip has it.
        let middle = placed(transcript, [clip("clip_a", at: 0, playing: 5, 9.5), clip("clip_b", at: 4.5, playing: 9.5, 15)])
        XCTAssertEqual(middle.map(\.clip), ["clip_a", "clip_b"])
    }

    /// The report's cut, 28.35 to 28.95, inside the silence after
    /// "workbench": with the engine's times "of" kept only 0.48 s of its
    /// 1.08 and vanished; trimmed to the voice it plays once, after the cut.
    func testTheWorkbenchCutInThePauseAfterWorkbench() {
        let clips = [clip("clip_a", at: 0, playing: 25.83, 28.35), clip("clip_b", at: 2.52, playing: 28.95, 30.83)]
        let raw = Transcript(language: "en", engine: "test", words: [word("workbench", 27.66, 28.14), word("of", 28.14, 29.22), word("this", 29.22, 29.40)])
        XCTAssertEqual(placed(raw, clips).map(\.text), ["workbench", "this"])
        let aligned = Transcript(language: "en", engine: "test", words: [word("workbench", 27.66, 28.26), word("of", 29.05, 29.22), word("this", 29.22, 29.40)])
        let words = placed(aligned, clips)
        XCTAssertEqual(words.map(\.text), ["workbench", "of", "this"])
        XCTAssertEqual(words.map(\.clip), ["clip_a", "clip_b", "clip_b"])
    }

    func testAStumbleInsideACutIsDropped() {
        let transcript = Transcript(language: "en", engine: "test", words: [
            word("worked.", 48.85, 49.45), word("He'd", 49.71, 49.86), word("like,", 49.86, 49.96),
            word("it", 50.24, 50.35), word("worked.", 50.66, 51.14), word("I'll", 51.33, 51.60)
        ])
        // The stumble cut from 49.52 to 51.25.
        let words = placed(transcript, [clip("clip_a", at: 0, playing: 48.72, 49.52), clip("clip_b", at: 0.8, playing: 51.25, 55.92)])
        XCTAssertEqual(words.map(\.text), ["worked.", "I'll"])
        // Less than half left is cut; exactly half left stays.
        let partly = Transcript(language: "en", engine: "test", words: [word("mostly", 10, 11), word("half", 20, 21)])
        XCTAssertEqual(placed(partly, [clip("clip_a", at: 0, playing: 0, 10.4), clip("clip_b", at: 10.4, playing: 20.5, 30)]).map(\.text), ["half"])
    }

    func testAClipAtDoubleSpeed() {
        let transcript = Transcript(language: "en", engine: "test", words: [
            word("before", 9.8, 10.6), word("inside", 12, 13), word("after", 19.5, 20.6)
        ])
        // Plays file 10...20 at double speed from 100 on the timeline.
        let words = placed(transcript, [clip("clip_fast", at: 100, playing: 10, 20, speed: 2)])
        XCTAssertEqual(words.map(\.text), ["before", "inside"], "\"after\" keeps 0.5 of its 1.1 s")
        XCTAssertEqual(words[0].start, 100, accuracy: 0.001)
        XCTAssertEqual(words[0].end, 100.3, accuracy: 0.001)
        XCTAssertEqual(words[1].start, 101, accuracy: 0.001)
        XCTAssertEqual(words[1].end, 101.5, accuracy: 0.001)
        // Shares are media time: across a cut from a 2x clip to a 1x one,
        // the 2x side keeps more of the word although it plays for less.
        let split = placed(Transcript(language: "en", engine: "test", words: [word("across", 9, 10.5)]),
                           [clip("clip_fast", at: 0, playing: 0, 10, speed: 2), clip("clip_slow", at: 5, playing: 10, 20)])
        XCTAssertEqual(split.map(\.clip), ["clip_fast"])
        XCTAssertEqual(split[0].start, 4.5, accuracy: 0.001)
        XCTAssertEqual(split[0].end, 5, accuracy: 0.001)
    }

    func testAStretchUsedTwiceShowsItsWordsTwice() {
        let transcript = Transcript(language: "en", engine: "test", words: [word("again", 1, 2)])
        let words = placed(transcript, [clip("clip_a", at: 0, playing: 0, 5), clip("clip_b", at: 10, playing: 0, 5)])
        XCTAssertEqual(words.map(\.clip), ["clip_a", "clip_b"])
        XCTAssertEqual(words.map(\.start), [1, 11], accuracy: 0.001)
    }

    func testFreezeFramesAndStoppedClipsPlayNoWords() {
        let transcript = Transcript(language: "en", engine: "test", words: [word("still", 1, 2)])
        var frozen = clip("clip_a", at: 0, playing: 0, 5)
        frozen.freezeFrame = true
        XCTAssertTrue(transcript.placements(on: [frozen]).isEmpty)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, message, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, message, file: file, line: line) }
}
