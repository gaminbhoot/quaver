import AVFoundation
import Combine
import Foundation

// Phase 3.5 minimal graceful-failure tests — ensures unsupported formats don't crash.
// WAV/M4A are verified native in Phase3PlaybackTests; this file only proves
// that FLAC/Ogg/Opus/WMA etc. (currently without a decoder fallback) fail gracefully:
//   • duration stays 0
//   • isPlaying stays false
//   • no crash / no exception
//   • engine recovers and can play a valid file afterwards
//
// Future: when FallbackBackend (Symphonia → PCM) lands, these same files should
// become playable and this test will be updated to expect success. The PlaybackEngine
// public API does not change — only the backend behind it.

var gracefulFailures: [String] = []
func gracefulCheck(_ cond: Bool, _ msg: String) {
    if !cond { gracefulFailures.append(msg); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}

let gracefulDir = URL(fileURLWithPath: "/tmp/quaver_phase3_graceful_fixtures")

func ensureGracefulFixtures() throws -> [String: URL] {
    try FileManager.default.createDirectory(at: gracefulDir, withIntermediateDirectories: true)
    let wav = gracefulDir.appendingPathComponent("valid.wav")
    if !FileManager.default.fileExists(atPath: wav.path) {
        let sr: Double = 44100
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: wav, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(sr * 1.5)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)
    }
    for ext in ["ogg","opus","flac","wma","ape","ac3","mka"] {
        let url = gracefulDir.appendingPathComponent("dummy.\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try "not audio".write(to: url, atomically: true, encoding: .utf8)
        }
    }
    return ["wav": wav, "ogg": gracefulDir.appendingPathComponent("dummy.ogg")]
}

@MainActor
func waitForGraceful(_ cond: @escaping () -> Bool, timeout: Double = 2.0) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return cond()
}

@MainActor
func testUnsupportedFailsGracefully() async {
    _ = try? ensureGracefulFixtures()
    let wav = gracefulDir.appendingPathComponent("valid.wav")
    let ogg = gracefulDir.appendingPathComponent("dummy.ogg")
    let flac = gracefulDir.appendingPathComponent("dummy.flac")
    let wma = gracefulDir.appendingPathComponent("dummy.wma")
    for (label, url) in [("ogg", ogg), ("flac", flac), ("wma", wma)] {
        let track = TrackMetadata(path: url.path, title: "t", artist: "a", album: "b", duration: 10, format: label.uppercased(), coverDataURL: nil, lyricPath: nil)
        let eng = NativePlaybackEngine(library: [track])
        eng.play(trackAt: 0)
        try? await Task.sleep(nanoseconds: 600_000_000)
        gracefulCheck(eng.state.duration == 0, "[\(label)] unsupported dummy duration stays 0 (graceful, not crash)")
        gracefulCheck(!eng.state.isPlaying, "[\(label)] unsupported dummy isPlaying stays false")
        gracefulCheck(eng.currentTrack?.path == url.path, "[\(label)] currentTrack still set even though unplayable (library not silently dropped)")
        let validTrack = TrackMetadata(path: wav.path, title: "valid", artist: "a", album: "b", duration: 10, format: "WAV", coverDataURL: nil, lyricPath: nil)
        eng.setLibrary([validTrack])
        eng.play(trackAt: 0)
        let ok = await waitForGraceful({ eng.state.duration > 0.1 }, timeout: 3)
        gracefulCheck(ok, "[\(label)] engine recovers and plays valid WAV after unsupported failure")
    }
}
