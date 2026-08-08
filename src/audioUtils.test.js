import { describe, it, expect } from 'vitest';
import { formatTime, parseLRC, getNextTrackIndex, getPrevTrackIndex } from './audioUtils.js';

describe('audioUtils Unit Test Suite', () => {

  describe('formatTime()', () => {
    it('formats 0 seconds to 0:00', () => {
      expect(formatTime(0)).toBe('0:00');
    });

    it('formats 65 seconds to 1:05', () => {
      expect(formatTime(65)).toBe('1:05');
    });

    it('formats 3599 seconds to 59:59', () => {
      expect(formatTime(3599)).toBe('59:59');
    });

    it('handles NaN and negative values gracefully', () => {
      expect(formatTime(NaN)).toBe('0:00');
      expect(formatTime(-10)).toBe('0:00');
    });
  });

  describe('parseLRC()', () => {
    it('parses valid LRC lyrics and returns sorted timestamps', () => {
      const lrcContent = `
[00:03.00] Line One
[00:01.50] Line Zero
[00:06.25] Line Two
      `;

      const result = parseLRC(lrcContent);
      expect(result).toHaveLength(3);
      expect(result[0]).toEqual({ time: 1.5, text: 'Line Zero' });
      expect(result[1]).toEqual({ time: 3.0, text: 'Line One' });
      expect(result[2]).toEqual({ time: 6.25, text: 'Line Two' });
    });

    it('handles invalid or empty LRC input', () => {
      expect(parseLRC('')).toEqual([]);
      expect(parseLRC(null)).toEqual([]);
      expect(parseLRC('Just plain text without LRC timestamps')).toEqual([]);
    });
  });

  describe('getNextTrackIndex() & getPrevTrackIndex()', () => {
    it('calculates sequential next track index', () => {
      expect(getNextTrackIndex(0, 3, false)).toBe(1);
      expect(getNextTrackIndex(1, 3, false)).toBe(2);
    });

    it('wraps around to index 0 when reaching the end of playlist', () => {
      expect(getNextTrackIndex(2, 3, false)).toBe(0);
    });

    it('calculates previous track index with wrap-around', () => {
      expect(getPrevTrackIndex(2, 3)).toBe(1);
      expect(getPrevTrackIndex(0, 3)).toBe(2);
    });

    it('returns -1 for empty playlist', () => {
      expect(getNextTrackIndex(0, 0, false)).toBe(-1);
      expect(getPrevTrackIndex(0, 0)).toBe(-1);
    });
  });

});
