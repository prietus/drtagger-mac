import Foundation
import Testing
@testable import LibraryKit

@Suite("DiscTOC")
struct DiscTOCTests {

    // Real rips whose REM DISCID was written by EAC; the MusicBrainz IDs were
    // cross-checked with an independent implementation on 2026-09-20.
    static let walkin = """
    REM DISCID 3C08E205
    FILE "Walkin.flac" WAVE
      TRACK 01 AUDIO
        INDEX 00 00:00:00
        INDEX 01 00:00:37
      TRACK 02 AUDIO
        INDEX 00 13:27:60
        INDEX 01 13:29:37
      TRACK 03 AUDIO
        INDEX 00 21:47:27
        INDEX 01 21:48:54
      TRACK 04 AUDIO
        INDEX 00 26:32:69
        INDEX 01 26:33:69
      TRACK 05 AUDIO
        INDEX 00 30:57:74
        INDEX 01 30:57:74
    """
    static let walkinFrames = 170557          // 100287516 samples / 588

    @Test func matchesRealRipIdentifiers() throws {
        let cue = try CueSheet.parse(text: Self.walkin)
        let toc = try DiscTOC(cue: cue, fileFrames: [Self.walkinFrames])
        #expect(toc.firstTrack == 1)
        #expect(toc.lastTrack == 5)
        #expect(toc.trackOffsets == [37 + 150, 60712 + 150, 98154 + 150, 119544 + 150, 139349 + 150])
        #expect(toc.leadOut == 170557 + 150)
        #expect(toc.freeDBDiscID == "3C08E205")
        #expect(toc.musicBrainzDiscID == "iOSL4j4VX_YutvVxL4QjWVsVEJE-")
        #expect(toc.ctdbTOCString == "37:60712:98154:119544:139349:170557")
        #expect(toc.musicBrainzTOCString == "1 5 170707 187 60862 98304 119694 139499")
    }

    @Test func secondRealRip() throws {
        let starts = [0, 13195, 31742, 52522, 75077, 104117, 120325, 139585, 164567, 184517, 200405, 223842, 246112]
        var text = "FILE \"a.flac\" WAVE\n"
        for (i, s) in starts.enumerated() {
            let m = s / (60 * 75), sec = (s / 75) % 60, f = s % 75
            text += "  TRACK \(String(format: "%02d", i + 1)) AUDIO\n    INDEX 01 \(String(format: "%02d:%02d:%02d", m, sec, f))\n"
        }
        let toc = try DiscTOC(cue: try CueSheet.parse(text: text), fileFrames: [266687])
        #expect(toc.freeDBDiscID == "B10DE30D")
        #expect(toc.musicBrainzDiscID == "F76P4DCRiKgvHXm9SsWgm88xMMQ-")
    }

    @Test func multiFileSheetsAreLaidOutBackToBack() throws {
        let text = """
        FILE "01.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "02.wav" WAVE
          TRACK 02 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:02:00
        FILE "03.wav" WAVE
          TRACK 03 AUDIO
            INDEX 01 00:00:00
        """
        let toc = try DiscTOC(cue: try CueSheet.parse(text: text), fileFrames: [1000, 2000, 3000])
        #expect(toc.trackOffsets == [150, 1000 + 150 + 150, 3000 + 150])
        #expect(toc.leadOut == 6150)
    }

    @Test func enhancedCDLeadOutStopsBeforeDataTrack() throws {
        let text = """
        FILE "a.bin" BINARY
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 10:00:00
          TRACK 03 MODE1/2352
            INDEX 01 30:00:00
        """
        let toc = try DiscTOC(cue: try CueSheet.parse(text: text), fileFrames: [200_000])
        #expect(toc.lastTrack == 2)
        #expect(toc.trackOffsets.count == 2)
        #expect(toc.leadOut == 30 * 60 * 75 + 150 - 11400)
    }

    @Test func rejectsBrokenSheets() throws {
        let missing = try CueSheet.parse(text: "FILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n  INDEX 00 00:00:00\n")
        #expect(throws: DiscTOC.TOCError.missingIndex01(track: 1)) {
            try DiscTOC(cue: missing, fileFrames: [100])
        }
        let ok = try CueSheet.parse(text: Self.walkin)
        #expect(throws: DiscTOC.TOCError.fileCountMismatch(expected: 1, got: 2)) {
            try DiscTOC(cue: ok, fileFrames: [1, 2])
        }
    }
}

@Suite("CueSplitPlan")
struct CueSplitPlanTests {

    @Test func gapsGoToPreviousTrackAndShortLeadInIsDropped() throws {
        let cue = try CueSheet.parse(text: DiscTOCTests.walkin)
        let total = Int64(DiscTOCTests.walkinFrames) * 588
        let plan = try CueSplitPlan.make(cue: cue, fileSampleCounts: [total], sampleRate: 44100)

        #expect(plan.hiddenTrack == nil)              // 37 frames < 150 threshold
        #expect(plan.droppedLeadInSamples == 37 * 588)
        #expect(plan.tracks.count == 5)
        #expect(plan.tracks[0].startSample == 37 * 588)
        #expect(plan.tracks[0].endSample == 60712 * 588)   // track 2's INDEX 01, pregap stays in track 1
        #expect(plan.tracks[4].endSample == total)
        #expect(plan.tracks.map(\.sampleCount).reduce(0, +) + plan.droppedLeadInSamples == total)
    }

    @Test func longLeadInBecomesHiddenTrack() throws {
        let text = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 00 00:00:00
            INDEX 01 00:10:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 01:00:00
        """
        let cue = try CueSheet.parse(text: text)
        let plan = try CueSplitPlan.make(cue: cue, fileSampleCounts: [5_000_000], sampleRate: 44100)
        let htoa = try #require(plan.hiddenTrack)
        #expect(htoa.startSample == 0)
        #expect(htoa.endSample == 10 * 75 * 588)
        #expect(plan.numberedTracks.map(\.number) == [1, 2])
        #expect(plan.numberedTracks[0].title == "One")
        #expect(plan.numberedTracks[1].endSample == 5_000_000)
        #expect(plan.droppedLeadInSamples == 0)

        let strict = try CueSplitPlan.make(cue: cue, fileSampleCounts: [5_000_000], sampleRate: 44100, htoaThresholdFrames: 1000)
        #expect(strict.hiddenTrack == nil)
        #expect(strict.droppedLeadInSamples == 10 * 75 * 588)
    }

    @Test func multiFileWithGapsPrepended() throws {
        // EAC "gaps prepended": each file starts with its track's pregap.
        let text = """
        FILE "01.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "02.wav" WAVE
          TRACK 02 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:02:00
        FILE "03.wav" WAVE
          TRACK 03 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:01:00
        """
        let cue = try CueSheet.parse(text: text)
        let f1: Int64 = 1000 * 588, f2: Int64 = 2000 * 588, f3: Int64 = 3000 * 588
        let plan = try CueSplitPlan.make(cue: cue, fileSampleCounts: [f1, f2, f3], sampleRate: 44100)
        #expect(plan.tracks.count == 3)
        #expect(plan.tracks[0].startSample == 0)
        #expect(plan.tracks[0].endSample == f1 + 150 * 588)        // absorbs track 2's 2 s pregap
        #expect(plan.tracks[1].startSample == f1 + 150 * 588)
        #expect(plan.tracks[1].endSample == f1 + f2 + 75 * 588)
        #expect(plan.tracks[2].endSample == f1 + f2 + f3)
        #expect(plan.totalSamples == f1 + f2 + f3)
    }

    @Test func highResRatesAndErrors() throws {
        let cue = try CueSheet.parse(text: DiscTOCTests.walkin)
        let plan = try CueSplitPlan.make(cue: cue, fileSampleCounts: [Int64(DiscTOCTests.walkinFrames) * 1176], sampleRate: 88200)
        #expect(plan.tracks[0].startSample == 37 * 1176)

        #expect(throws: CueSplitPlan.PlanError.unsupportedSampleRate(44000)) {
            try CueSplitPlan.make(cue: cue, fileSampleCounts: [1000], sampleRate: 44000)
        }
        #expect(throws: CueSplitPlan.PlanError.indexBeyondFile(track: 2)) {
            try CueSplitPlan.make(cue: cue, fileSampleCounts: [1000 * 588], sampleRate: 44100)
        }
    }
}
