import Foundation
import Testing
@testable import drtagger

// These run inside the drtagger.app test host, so Bundle.main is the real
// app bundle and the embedded helpers from scripts/embed-ffmpeg.sh are
// visible. They double as an integration check of the ffmpeg build.
@Suite("FFmpegLocator")
struct FFmpegLocatorTests {

    @Test func prefersEmbeddedBinaryWhenNoOverride() throws {
        let locator = FFmpegLocator(overridePath: "")
        let location = try #require(locator.locate())
        #expect(location.source == .bundled)
        #expect(location.ffmpeg.lastPathComponent == "ffmpeg")
        #expect(location.ffprobe?.lastPathComponent == "ffprobe")
    }

    @Test func ignoresInvalidOverride() throws {
        let locator = FFmpegLocator(overridePath: "/nonexistent/ffmpeg")
        let location = try #require(locator.locate())
        #expect(location.source != .override)
    }

    @Test func embeddedBuildIsLGPLWithRequiredComponents() async throws {
        let info = try await FFmpegLocator(overridePath: "").inspect()
        #expect(info.location.source == .bundled)
        #expect(info.versionLine.hasPrefix("ffmpeg version"))
        #expect(!info.isGPL, "embedded ffmpeg must not be a GPL build")
        #expect(info.hasDSTDecoder)
    }

    @Test func processRunnerCapturesOutputAndStatus() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                 arguments: ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
    }
}
