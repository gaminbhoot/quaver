import Foundation

/// Pure, deterministic lyrics sync. No timers. Single clock: PlaybackEngine.currentTime.
/// Mirrors `src/lyricsEngine.js` contracts so existing tests port 1:1.
struct LyricLine: Equatable, Codable { var time: Double; var text: String }

enum LyricSynchronizer {
    /// Mirrors `getActiveLyricIndex`. Lyrics must be sorted by `time` (as `parseLRC` does).
    static func activeIndex(lyrics: [LyricLine], currentTime: Double) -> Int {
        guard !lyrics.isEmpty else { return -1 }
        var active = -1
        for (i, line) in lyrics.enumerated() {
            guard line.time.isFinite else { continue }
            if currentTime >= line.time { active = i } else { break }
        }
        return active
    }

    /// Independent oracle — brute-force, obviously correct — for test cross-check.
    /// Mirrors `independentActiveLyric`.
    static func independentActiveIndex(lyrics: [LyricLine], currentTime: Double) -> Int {
        guard !lyrics.isEmpty else { return -1 }
        var best = -1; var bestTime = -Double.infinity
        for (i, l) in lyrics.enumerated() where l.time.isFinite && l.time <= currentTime {
            if l.time > bestTime || (l.time == bestTime && i > best) { best = i; bestTime = l.time }
        }
        return best
    }

    /// Mirrors `getLyricLineDuration`. Capped: raw > 12 → min(raw,7), floor 0.6.
    static func lineDuration(lyrics: [LyricLine], index: Int, audioDuration: Double?) -> Double {
        guard lyrics.indices.contains(index), lyrics[index].time.isFinite else { return 0.6 }
        let cur = lyrics[index].time
        let next: Double
        if let n = lyrics[safe: index + 1]?.time, n.isFinite { next = n }
        else if let d = audioDuration, d.isFinite { next = d }
        else { next = cur + 4 }
        let raw = next - cur
        let capped = raw > 12 ? min(raw, 7) : raw
        return max(0.6, capped)
    }

    /// Mirrors `getWordProgresses`: split on /(\s+)/, per-word progress.
    static func wordProgresses(lyrics: [LyricLine], lineIndex: Int, currentTime: Double, audioDuration: Double?) -> [Double] {
        guard lyrics.indices.contains(lineIndex) else { return [] }
        let line = lyrics[lineIndex]
        let words = line.text.split { $0.isWhitespace }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let dur = lineDuration(lyrics: lyrics, index: lineIndex, audioDuration: audioDuration)
        let elapsed = currentTime - line.time
        let lineProgress = max(0, min(1, elapsed / dur))
        let n = Double(words.count)
        return (0..<words.count).map { wi in max(0, min(1, lineProgress * n - Double(wi))) }
    }

    /// Mirrors `parseLRC` (audioUtils.js): `[mm:ss.xx]` / `[mm:ss.xxx]`, multiple stamps per line, sorted.
    static func parseLRC(_ text: String) -> [LyricLine] {
        guard !text.isEmpty else { return [] }
        let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [LyricLine] = []
        for rawLine in text.components(separatedBy: "\n") {
            let ns = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let lyricText = regex.stringByReplacingMatches(in: rawLine, range: NSRange(location: 0, length: ns.length), withTemplate: "").trimmingCharacters(in: .whitespaces)
            guard !lyricText.isEmpty else { continue }
            for m in matches {
                let mm = (ns.substring(with: m.range(at: 1)) as NSString).doubleValue
                let ss = (ns.substring(with: m.range(at: 2)) as NSString).doubleValue
                let fracStr = ns.substring(with: m.range(at: 3))
                let frac = (fracStr as NSString).doubleValue / (fracStr.count == 3 ? 1000 : 100)
                out.append(LyricLine(time: mm * 60 + ss + frac, text: lyricText))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
