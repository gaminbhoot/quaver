/**
 * Formats duration seconds into MM:SS format.
 * @param {number} seconds 
 * @returns {string}
 */
export function formatTime(seconds) {
  if (isNaN(seconds) || seconds < 0) return '0:00';
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60).toString().padStart(2, '0');
  return `${m}:${s}`;
}

/**
 * Parses LRC synchronized lyrics format.
 * @param {string} text 
 * @returns {Array<{time: number, text: string}>}
 */
export function parseLRC(text) {
  if (!text || typeof text !== 'string') return [];
  const lines = text.split('\n');
  const result = [];
  const timeRegAll = /\[(\d{2}):(\d{2})\.(\d{2,3})\]/g;

  for (let line of lines) {
    const matches = [...line.matchAll(timeRegAll)];
    if (matches.length === 0) continue;
    const lyricText = line.replace(timeRegAll, '').trim();
    if (!lyricText) continue;
    for (const match of matches) {
      const minutes = parseInt(match[1], 10);
      const seconds = parseInt(match[2], 10);
      const ms = parseInt(match[3], 10);
      const time = minutes * 60 + seconds + (ms / (match[3].length === 3 ? 1000 : 100));
      result.push({ time, text: lyricText });
    }
  }
  return result.sort((a, b) => a.time - b.time);
}

/**
 * Determines the next track index based on shuffle and repeat settings.
 * @param {number} currentIndex 
 * @param {number} totalTracks 
 * @param {boolean} isShuffle 
 * @returns {number}
 */
export function getNextTrackIndex(currentIndex, totalTracks, isShuffle) {
  if (totalTracks <= 0) return -1;
  if (isShuffle) {
    return Math.floor(Math.random() * totalTracks);
  }
  let nextIndex = currentIndex + 1;
  if (nextIndex >= totalTracks) {
    nextIndex = 0;
  }
  return nextIndex;
}

/**
 * Determines the previous track index.
 * @param {number} currentIndex 
 * @param {number} totalTracks 
 * @returns {number}
 */
export function getPrevTrackIndex(currentIndex, totalTracks) {
  if (totalTracks <= 0) return -1;
  let prevIndex = currentIndex - 1;
  if (prevIndex < 0) {
    prevIndex = totalTracks - 1;
  }
  return prevIndex;
}
