import Foundation
import Testing
@testable import LibraryKit

@Suite("CueSheet")
struct CueSheetTests {

    static let singleImage = """
    REM GENRE Rock
    REM DATE 1971
    REM DISCID 8A0B5F0A
    REM COMMENT "Universal Music – UICY-40164\\Barcode: 4988031277102\\Reissue"
    CATALOG 0000000000000
    PERFORMER "The Rolling Stones"
    TITLE "Sticky Fingers"
    FILE "Sticky Fingers.flac" WAVE
      TRACK 01 AUDIO
        TITLE "Brown Sugar"
        PERFORMER "The Rolling Stones"
        INDEX 00 00:00:00
        INDEX 01 00:00:33
      TRACK 02 AUDIO
        TITLE "Sway"
        ISRC GBUM71029604
        INDEX 00 03:48:20
        INDEX 01 03:50:12
      TRACK 03 AUDIO
        TITLE "Wild Horses"
        INDEX 01 07:41:60
    """

    @Test func parsesSingleImageSheet() throws {
        let sheet = try CueSheet.parse(text: Self.singleImage)
        #expect(sheet.title == "Sticky Fingers")
        #expect(sheet.performer == "The Rolling Stones")
        #expect(sheet.isSingleFile)
        #expect(sheet.files[0].name == "Sticky Fingers.flac")
        #expect(sheet.files[0].type == "WAVE")
        #expect(sheet.audioTracks.count == 3)

        let t2 = sheet.audioTracks[1]
        #expect(t2.number == 2)
        #expect(t2.title == "Sway")
        #expect(t2.isrc == "GBUM71029604")
        #expect(t2.pregapStart == CueTime(msf: "03:48:20"))
        #expect(t2.start == CueTime(msf: "03:50:12"))

        #expect(sheet.date == "1971")
        #expect(sheet.genre == "Rock")
        #expect(sheet.discID == "8A0B5F0A")
        #expect(sheet.rem("COMMENT")?.hasPrefix("Universal Music") == true, "REM values lose their quotes")
        #expect(sheet.trackOnePregap?.frames == 33)
    }

    @Test func extractsIdentificationHints() throws {
        let sheet = try CueSheet.parse(text: Self.singleImage)
        // CATALOG of all zeros is a placeholder; the REM COMMENT carries the real barcode.
        #expect(sheet.barcodeHint == "4988031277102")
        #expect(sheet.catalogNumberHints == ["UICY-40164"])

        var withCatalog = sheet
        withCatalog.catalog = "0602547858917"
        #expect(withCatalog.barcodeHint == "0602547858917")
    }

    @Test func parsesMultiFileSheetAndUnquotedNames() throws {
        let text = """
        TITLE Ella and Oscar
        FILE 01 - Mean to Me.wav WAVE
          TRACK 01 AUDIO
            TITLE "Mean to Me"
            INDEX 00 00:00:00
            INDEX 01 00:00:32
        FILE "02 - How Long.wav" WAVE
          TRACK 02 AUDIO
            INDEX 01 00:00:00
        """
        let sheet = try CueSheet.parse(text: text)
        #expect(sheet.title == "Ella and Oscar")
        #expect(sheet.files.count == 2)
        #expect(sheet.files[0].name == "01 - Mean to Me.wav")
        #expect(sheet.files[1].name == "02 - How Long.wav")
        #expect(!sheet.isSingleFile)
        #expect(sheet.tracks.map(\.number) == [1, 2])
    }

    @Test func rejectsSheetsWithoutFiles() {
        #expect(throws: CueSheet.ParseError.noFiles) {
            try CueSheet.parse(text: "TITLE \"x\"\nPERFORMER \"y\"\n")
        }
        #expect(throws: CueSheet.ParseError.empty) {
            try CueSheet.parse(text: "\n\n")
        }
    }

    @Test func cueTimeArithmetic() throws {
        let t = try #require(CueTime(msf: "03:50:12"))
        #expect(t.frames == (3 * 60 + 50) * 75 + 12)
        #expect(t.msfString == "03:50:12")
        #expect(t.samples(sampleRate: 44100) == t.frames * 588)
        #expect(CueTime(msf: "00:00:75") == nil)
        #expect(CueTime(msf: "1:2") == nil)
        #expect(CueTime(msf: "100:00:00")?.minutes == 100)
    }

    @Test func tokenizerKeepsQuotedStringsAndEmptyQuotes() {
        #expect(CueSheet.tokenize("FILE \"a b.flac\" WAVE") == ["FILE", "a b.flac", "WAVE"])
        #expect(CueSheet.tokenize("TITLE \"\"") == ["TITLE", ""])
        #expect(CueSheet.tokenize("  INDEX 01   00:02:00 ") == ["INDEX", "01", "00:02:00"])
    }

    // MARK: Encodings

    @Test func decodesUTF8WithBOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("TITLE \"Leño – ¡Corre!\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n".utf8))
        let sheet = try CueSheet.parse(data: data)
        #expect(sheet.encodingName == "utf-8-bom")
        #expect(sheet.title == "Leño – ¡Corre!")
    }

    @Test func decodesCP1252SmartQuotes() throws {
        // "Sailor’s Lament" with 0x92 (CP1252 right single quote) and an en dash 0x96.
        var bytes = Array("TITLE \"Sailor".utf8)
        bytes += [0x92]
        bytes += Array("s Lament ".utf8)
        bytes += [0x96]
        bytes += Array(" Live\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n".utf8)
        let sheet = try CueSheet.parse(data: Data(bytes))
        #expect(sheet.encodingName == "cp1252")
        #expect(sheet.title == "Sailor’s Lament – Live")
    }

    @Test func decodesShiftJIS() throws {
        let title = "坂本龍一 - 戦場のメリークリスマス"
        let sjis = try #require(title.data(using: .shiftJIS))
        var data = Data("TITLE \"".utf8)
        data.append(sjis)
        data.append(Data("\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n".utf8))
        let sheet = try CueSheet.parse(data: data)
        #expect(sheet.encodingName == "shift_jis")
        #expect(sheet.title == title)
    }

    @Test func decodesCP1251() throws {
        let title = "Кино - Группа крови"
        let cp = try #require(title.data(using: .windowsCP1251))
        var data = Data("TITLE \"".utf8)
        data.append(cp)
        data.append(Data("\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n".utf8))
        let sheet = try CueSheet.parse(data: data)
        #expect(sheet.encodingName == "cp1251")
        #expect(sheet.title == title)
    }

    @Test func spanishAccentsStayLatin() throws {
        // "¡Qué desilusión!" in Latin-1: bytes A1, E9, F3 must not be mistaken for Cyrillic.
        let title = "¡Qué desilusión!"
        let latin = try #require(title.data(using: .windowsCP1252))
        var data = Data("TITLE \"".utf8)
        data.append(latin)
        data.append(Data("\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n".utf8))
        let sheet = try CueSheet.parse(data: data)
        #expect(sheet.encodingName == "cp1252")
        #expect(sheet.title == title)
    }
}
