/**
 * Pure lyrics synchronization engine - single source of truth is audio.currentTime
 * All functions are deterministic, side-effect free, and match the app's runtime.
 * Keep this and main.js in sync: main.js inlines parse/format for Tauri compat,
 * but getActiveLyricIndex here is the contract the tests enforce.
 */

export function getActiveLyricIndex(lyrics, currentTime) {
  if (!Array.isArray(lyrics) || lyrics.length === 0) return -1;
  let active = -1;
  for (let i = 0; i < lyrics.length; i++) {
    const t = lyrics[i]?.time;
    if (typeof t !== 'number' || !Number.isFinite(t)) continue;
    if (currentTime >= t) active = i;
    else break; // lyrics sorted by parseLRC
  }
  return active;
}

// Re-exported for main.js parity check — main.js mirrors parseLRC/formatTime inline
// for Tauri asset-protocol reasons; this keeps the lookup contract single-sourced.

export function getLyricLineDuration(lyrics, index, audioDuration) {
  if (!Array.isArray(lyrics) || index < 0 || index >= lyrics.length) return 0.6;
  const cur = lyrics[index]?.time;
  if (!Number.isFinite(cur)) return 0.6;
  const next = lyrics[index + 1]?.time;
  let nextTime;
  if (Number.isFinite(next)) nextTime = next;
  else if (Number.isFinite(audioDuration)) nextTime = audioDuration;
  else nextTime = cur + 4;
  const raw = nextTime - cur;
  const capped = raw > 12 ? Math.min(raw, 7) : raw;
  return Math.max(0.6, capped);
}

/**
 * Word-level progress for karaoke: returns array of progresses 0..1 per word in active line
 */
export function getWordProgresses(lyrics, lineIndex, currentTime, audioDuration) {
  if (lineIndex < 0 || !Array.isArray(lyrics) || lineIndex >= lyrics.length) return [];
  const line = lyrics[lineIndex];
  if (!line || typeof line.text !== 'string') return [];
  const words = line.text.split(/(\s+)/).filter(p => !/^\s+$/.test(p) && p.length > 0);
  // Mirror renderLyrics: splits by (\s+) and creates word spans only for non-whitespace parts
  // For pure engine, count whitespace-separated tokens: line.text.trim().split(/\s+/)
  // But we follow actual DOM: words are text.split(/(\s+)/) non-whitespace parts
  const wordCount = words.length;
  if (wordCount === 0) return [];
  const duration = getLyricLineDuration(lyrics, lineIndex, audioDuration);
  const elapsed = currentTime - line.time;
  const lineProgress = Math.max(0, Math.min(1, elapsed / duration));
  return words.map((_, wi) => Math.max(0, Math.min(1, lineProgress * wordCount - wi)));
}

// Independent resolver for expected active lyric - brute force, obviously correct, separate from getActiveLyricIndex implementation
export function independentActiveLyric(lyrics, currentTime) {
  if (!Array.isArray(lyrics) || lyrics.length === 0) return -1;
  let best = -1;
  let bestTime = -Infinity;
  for (let i = 0; i < lyrics.length; i++) {
    const t = lyrics[i]?.time;
    if (typeof t !== 'number' || !Number.isFinite(t)) continue;
    if (t <= currentTime && t > bestTime) {
      // For duplicate timestamps, latest index wins if time equal and >=, but spec says sorted stable; brute force picks last with <= time and max time, or if tie picks later index
      best = i;
      bestTime = t;
    } else if (t <= currentTime && t === bestTime && i > best) {
      best = i;
    }
  }
  // However getActiveLyricIndex relies on sorted order and picks last <= time via break; for identical timestamps that means last duplicate wins which matches above
  // For unsorted input, independent resolver still gives correct latest <= time regardless of order, but app sorts, so we normalize by sorting copy
  // For test fixtures we use sorted lyrics, so both agree
  return best;
}
