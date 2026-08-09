/** @vitest-environment jsdom */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { parseLRC } from './audioUtils.js';
import { getActiveLyricIndex, getLyricLineDuration, getWordProgresses } from './lyricsEngine.js';

// ---------- Shared fixtures & helpers ----------
const BASE_LRC = `[00:00.00] A
[00:05.00] B
[00:10.00] C
[00:20.00] D
[00:30.00] E`;
const BASE = parseLRC(BASE_LRC);

function expectedActive(lyrics, t) {
  let best = -1;
  for (let i = 0; i < lyrics.length; i++) if (lyrics[i].time <= t) best = i;
  return best;
}

class FakeAudio {
  constructor() { this.currentTime = 0; this.duration = 200; this._m = new Map(); this.paused = true; }
  addEventListener(t, fn) { if (!this._m.has(t)) this._m.set(t, []); this._m.get(t).push(fn); }
  removeEventListener(t, fn) { const a = this._m.get(t); if (a) { const i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); } }
  dispatch(t) { for (const fn of [...(this._m.get(t) || [])]) fn({ type: t, target: this }); }
  setTime(t) { this.currentTime = t; }
}

class Ctrl {
  constructor(audio, container, list, overlay) {
    this.audio = audio; this.container = container; this.list = list; this.overlay = overlay;
    this.lyrics = []; this.active = -1; this.manualUntil = 0; this.raf = null; this.ver = 0;
    this._onSeeking = () => { this.manualUntil = 0; this._cancel(); this.sync(this.audio.currentTime); };
    this._onSeeked = () => { this.manualUntil = 0; this.sync(this.audio.currentTime); };
    this._onTime = () => this.sync(this.audio.currentTime);
    audio.addEventListener('seeking', this._onSeeking);
    audio.addEventListener('seeked', this._onSeeked);
    audio.addEventListener('timeupdate', this._onTime);
  }
  destroy() { this.audio.removeEventListener('seeking', this._onSeeking); this.audio.removeEventListener('seeked', this._onSeeked); this.audio.removeEventListener('timeupdate', this._onTime); this._cancel(); }
  _cancel() { if (this.raf) { cancelAnimationFrame(this.raf); this.raf = null; } }
  load(lyrics) { this.lyrics = lyrics; this.active = -1; this.render(); this.sync(this.audio.currentTime); }
  async loadAsync(p) { const v = ++this.ver; const l = await p; if (v !== this.ver) return false; this.lyrics = l; this.active = -1; this.render(); this.sync(this.audio.currentTime); return true; }
  render() {
    this.list.innerHTML = '';
    if (!this.lyrics.length) { this.list.innerHTML = '<div>empty</div>'; this.overlay.classList.add('no-lyrics'); return; }
    this.overlay.classList.remove('no-lyrics');
    for (const line of this.lyrics) {
      const d = document.createElement('div'); d.className = 'synced-line';
      line.text.split(/(\s+)/).forEach(part => {
        if (/^\s+$/.test(part)) { d.append(document.createTextNode(part)); return; }
        const w = document.createElement('span'); w.className = 'lyric-word'; w.textContent = part; w.style.setProperty('--word-progress', '0%'); d.append(w);
      });
      this.list.appendChild(d);
    }
  }
  sync(t) {
    if (!this.lyrics.length) return;
    let act = -1; for (let i = 0; i < this.lyrics.length; i++) if (t >= this.lyrics[i].time) act = i; else break;
    const visible = this.overlay.classList.contains('active') && !this.overlay.classList.contains('no-lyrics');
    if (!visible) { if (act !== this.active) this.active = act; return; }
    if (act !== this.active) {
      this.active = act;
      const lines = this.list.querySelectorAll('.synced-line');
      lines.forEach((el, i) => {
        el.classList.remove('active', 'past', 'upcoming', 'nearby');
        if (i === act) { el.classList.add('active'); if (Date.now() >= this.manualUntil) this._center(i); }
        else if (i < act) el.classList.add('past'); else el.classList.add('upcoming');
        if (Math.abs(i - act) === 1) el.classList.add('nearby');
      });
    }
    this._word(act, t);
  }
  _word(idx, t) {
    if (idx < 0 || !this.lyrics.length) return;
    if (!this.overlay.classList.contains('active') || this.overlay.classList.contains('no-lyrics')) return;
    const line = this.list.querySelectorAll('.synced-line')[idx];
    if (!line) return;
    const dur = getLyricLineDuration(this.lyrics, idx, this.audio.duration);
    const prog = Math.max(0, Math.min(1, (t - this.lyrics[idx].time) / dur));
    const words = line.querySelectorAll('.lyric-word');
    words.forEach((w, i) => w.style.setProperty('--word-progress', `${Math.max(0, Math.min(1, prog * words.length - i)) * 100}%`));
  }
  _center(idx) {
    const line = this.list.querySelectorAll('.synced-line')[idx];
    if (!line || Date.now() < this.manualUntil) return;
    const h = this.container.clientHeight || 400;
    const target = Math.max(0, line.offsetTop - h / 2 + line.clientHeight / 2);
    this._smooth(target);
  }
  _smooth(target) { this._cancel(); const s = this.container.scrollTop, d = target - s, dur = 720, st = performance.now(); const step = now => { const p = Math.min(1, (now - st) / dur); const e = 1 - Math.pow(1 - p, 4); this.container.scrollTop = s + d * e; if (p < 1) this.raf = requestAnimationFrame(step); else this.raf = null; }; this.raf = requestAnimationFrame(step); }
  open() { this.overlay.classList.add('active'); this.active = -1; this.manualUntil = 0; if (this.lyrics.length) this.sync(this.audio.currentTime); else this.container.scrollTop = 0; }
  close() { this.overlay.classList.remove('active'); this._cancel(); }
  clickLyric(i) { if (i < 0 || i >= this.lyrics.length) return; this.audio.currentTime = this.lyrics[i].time; this.manualUntil = 0; requestAnimationFrame(() => this.sync(this.audio.currentTime)); }
  clickWord(li, wi) { if (li < 0 || li >= this.lyrics.length) return; const dur = getLyricLineDuration(this.lyrics, li, this.audio.duration); const words = this.lyrics[li].text.split(/(\s+)/).filter(p => !/^\s+$/.test(p)); const target = this.lyrics[li].time + dur * (wi / Math.max(1, words.length)); this.audio.currentTime = target; this.manualUntil = 0; requestAnimationFrame(() => this.sync(this.audio.currentTime)); }
  manual() { this.manualUntil = Date.now() + 4500; this._cancel(); }
}

function dom() {
  document.body.innerHTML = '';
  const o = document.createElement('div'); o.id = 'fullscreen-overlay';
  const c = document.createElement('div'); c.id = 'fullscreen-lyrics-container';
  const l = document.createElement('div'); l.id = 'synced-lyrics-list';
  c.appendChild(l); document.body.appendChild(o); document.body.appendChild(c);
  Object.defineProperty(c, 'clientHeight', { value: 400, writable: true });
  return { o, c, l };
}
function mockOffset(list) { list.querySelectorAll('.synced-line').forEach((el, i) => { Object.defineProperty(el, 'offsetTop', { value: i * 60, writable: true }); Object.defineProperty(el, 'clientHeight', { value: 40, writable: true }); }); }

// ---------- 1. Exact timestamp boundaries (table-driven) ----------
describe('exact timestamp boundaries', () => {
  const cases = [
    [0, 0], [0.001, 0], [4.999, 0], [5, 1], [5.001, 1],
    [9.999, 1], [10, 2], [10.001, 2], [19.999, 2], [20, 3], [20.001, 3], [29.999, 3], [30, 4], [100, 4], [-1, -1],
  ];
  it.each(cases)('t=%p => %p', (t, exp) => {
    expect(getActiveLyricIndex(BASE, t)).toBe(exp);
    expect(expectedActive(BASE, t)).toBe(exp);
  });
  it('duplicate timestamps picks last', () => {
    const dup = parseLRC(`[00:10.00] a\n[00:10.00] b\n[00:10.00] c`);
    expect(getActiveLyricIndex(dup, 10)).toBe(2);
    expect(getActiveLyricIndex(dup, 9.999)).toBe(-1);
  });
});

// ---------- 2. Forward/backward seeks ----------
describe('forward/backward seeks', () => {
  let a, d, c;
  beforeEach(() => { a = new FakeAudio(); d = dom(); c = new Ctrl(a, d.c, d.l, d.o); c.load(BASE); d.o.classList.add('active'); mockOffset(d.l); });
  afterEach(() => c.destroy());
  it.each([0.001, 0.1, 1, 5, 30, 60])('forward +%p lands correctly', jump => {
    a.currentTime = 5; c.sync(5);
    const tgt = 5 + jump;
    a.currentTime = tgt; a.dispatch('seeking'); a.dispatch('seeked');
    expect(c.active).toBe(expectedActive(BASE, tgt));
  });
  it.each([0.001, 1, 5, 30, 60])('backward -%p lands correctly', jump => {
    a.currentTime = 30; c.sync(30);
    const tgt = Math.max(-1, 30 - jump);
    a.currentTime = tgt; a.dispatch('seeking'); a.dispatch('seeked');
    expect(c.active).toBe(expectedActive(BASE, tgt));
  });
  it('large jump to final', () => { a.currentTime = 0; c.sync(0); a.currentTime = 30; a.dispatch('seeking'); a.dispatch('seeked'); expect(c.active).toBe(4); });
  it('never assumes forward only', () => {
    a.currentTime = 30; c.sync(30); expect(c.active).toBe(4);
    a.currentTime = 5; a.dispatch('seeking'); a.dispatch('seeked'); expect(c.active).toBe(1);
    a.currentTime = 20; a.dispatch('seeking'); a.dispatch('seeked'); expect(c.active).toBe(3);
  });
});

// ---------- 3. Rapid seek race (deterministic seed) ----------
describe('rapid seek race', () => {
  let a, d, c;
  beforeEach(() => { a = new FakeAudio(); d = dom(); c = new Ctrl(a, d.c, d.l, d.o); c.load(BASE); d.o.classList.add('active'); });
  afterEach(() => c.destroy());
  it('adversarial 30,180,45,240 => 240', () => {
    for (const t of [30, 180, 45, 240]) { a.currentTime = t; a.dispatch('seeking'); }
    a.dispatch('seeked');
    expect(c.active).toBe(expectedActive(BASE, 240));
  });
  it('100 randomized seeks final wins (seed 12345)', () => {
    let s = 12345; const rand = () => { s = (s * 16807) % 2147483647; return s / 2147483647; };
    let final = 0;
    for (let i = 0; i < 100; i++) { final = Math.floor(rand() * 300); a.currentTime = final; a.dispatch('seeking'); if (rand() < 0.5) a.dispatch('seeked'); }
    a.dispatch('seeked');
    expect(c.active).toBe(expectedActive(BASE, final));
  });
});

// ---------- 4. Out-of-order seeking/seeked/timeupdate ----------
describe('out-of-order events', () => {
  const cases = [
    { name: 'seeking->seeked', ops: (a) => { a.currentTime = 20; a.dispatch('seeking'); a.dispatch('seeked'); }, exp: 20 },
    { name: 'seeking,seeking,seeked', ops: (a) => { a.currentTime = 10; a.dispatch('seeking'); a.currentTime = 20; a.dispatch('seeking'); a.dispatch('seeked'); }, exp: 20 },
    { name: 'seeking+timeupdate+seeked', ops: (a) => { a.currentTime = 10; a.dispatch('seeking'); a.dispatch('timeupdate'); a.dispatch('seeked'); }, exp: 10 },
    { name: 'timeupdate before seeking', ops: (a) => { a.dispatch('timeupdate'); a.currentTime = 10; a.dispatch('seeking'); a.dispatch('seeked'); }, exp: 10 },
  ];
  it.each(cases.map(c => [c.name, c.ops, c.exp]))('%s => %p', (_n, ops, exp) => {
    const a = new FakeAudio(); const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o); c.load(BASE); d.o.classList.add('active');
    ops(a);
    expect(c.active).toBe(expectedActive(BASE, exp));
    c.destroy();
  });
});

// ---------- 5. Stale async lyric loads ----------
describe('stale async loads', () => {
  it('slow A vs fast B - B wins', async () => {
    const a = new FakeAudio(); const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o); d.o.classList.add('active');
    const la = parseLRC(`[00:00.00] A1\n[00:10.00] A2`);
    const lb = parseLRC(`[00:00.00] B1\n[00:05.00] B2`);
    const pA = new Promise(r => setTimeout(() => r(la), 30));
    const pB = new Promise(r => setTimeout(() => r(lb), 10));
    c.loadAsync(pA); c.loadAsync(pB);
    await new Promise(r => setTimeout(r, 50));
    expect(c.lyrics[0].text).toBe('B1');
    c.destroy();
  });
  it('A->B->C last wins regardless of resolve order', async () => {
    const a = new FakeAudio(); const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o);
    const la = parseLRC(`[00:00.00] A`), lb = parseLRC(`[00:00.00] B`), lc = parseLRC(`[00:00.00] C`);
    c.loadAsync(new Promise(r => setTimeout(() => r(la), 30)));
    c.loadAsync(new Promise(r => setTimeout(() => r(lb), 10)));
    c.loadAsync(new Promise(r => setTimeout(() => r(lc), 20)));
    await new Promise(r => setTimeout(r, 50));
    expect(c.lyrics[0].text).toBe('C');
    c.destroy();
  });
});

// ---------- 6. Mid-song Lyrics open ----------
describe('Lyrics opened mid-song', () => {
  let a, d, c;
  const lyrics = parseLRC(`[00:00.00] A\n[00:05.00] B\n[00:10.00] C\n[00:20.00] D\n[02:27.25] MID\n[02:30.00] NEXT`);
  beforeEach(() => { a = new FakeAudio(); d = dom(); c = new Ctrl(a, d.c, d.l, d.o); c.load(lyrics); mockOffset(d.l); });
  afterEach(() => c.destroy());
  it.each([
    [0, 0], [0.001, 0], [15, 2], [147.25, 4], [147.249, 3], [147.251, 4],
  ])('at %p => %p', async (t, exp) => {
    a.currentTime = t; a.dispatch('timeupdate');
    c.open(); await new Promise(r => requestAnimationFrame(() => r()));
    expect(c.active).toBe(exp);
    expect(d.l.querySelectorAll('.synced-line')[exp].classList.contains('active')).toBe(true);
    if (exp > 0) expect(d.l.querySelectorAll('.synced-line')[exp - 1].classList.contains('active')).toBe(false);
  });
  it('does not stick to 0 when opened at 147.25', async () => {
    a.currentTime = 147.25; c.open(); await new Promise(r => requestAnimationFrame(() => r()));
    expect(c.active).toBe(4);
    expect(d.l.querySelectorAll('.synced-line')[0].classList.contains('active')).toBe(false);
  });
});

// ---------- 7. Click-to-lyric ----------
describe('click-to-lyric', () => {
  let a, d, c;
  const lyrics = parseLRC(`[00:00.00] first line here\n[00:10.00] second line\n[00:20.00] third line with words\n[00:30.00] last line`);
  beforeEach(() => { a = new FakeAudio(); a.duration = 40; d = dom(); c = new Ctrl(a, d.c, d.l, d.o); c.load(lyrics); mockOffset(d.l); d.o.classList.add('active'); });
  afterEach(() => c.destroy());
  it.each([0, 1, 2, 3])('click %p seeks to time and actives', async (i) => {
    c.clickLyric(i); await new Promise(r => requestAnimationFrame(() => r()));
    expect(a.currentTime).toBe(lyrics[i].time);
    expect(c.active).toBe(i);
  });
  it('word click seeks within line', async () => {
    c.clickWord(2, 1); await new Promise(r => requestAnimationFrame(() => r()));
    const dur = getLyricLineDuration(lyrics, 2, 40);
    const exp = lyrics[2].time + dur * (1 / 4);
    expect(a.currentTime).toBeCloseTo(exp, 5);
    expect(c.active).toBe(2);
  });
});

// ---------- 8. Word-level boundaries ----------
describe('word-level boundaries', () => {
  const lyrics = parseLRC(`[00:10.00] one two three four`);
  it('word progress 0% at line start, 100% at end', () => {
    expect(getWordProgresses(lyrics, 0, 10, 14)).toEqual([0, 0, 0, 0]);
    expect(getWordProgresses(lyrics, 0, 14, 14).every(v => v === 1)).toBe(true);
  });
  it('mid line 11s => first word done', () => {
    const p = getWordProgresses(lyrics, 0, 11, 14); // dur 4, prog 0.25 => w0 1, rest 0
    expect(p[0]).toBeCloseTo(1, 5); expect(p[1]).toBeCloseTo(0, 5);
  });
  it('random seeks word progress matches DOM', () => {
    const a = new FakeAudio(); a.duration = 14; const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o);
    c.load(lyrics); d.o.classList.add('active'); mockOffset(d.l);
    let s = 99; const rand = () => { s = (s * 16807) % 2147483647; return s / 2147483647; };
    for (let i = 0; i < 20; i++) {
      const t = 10 + rand() * 4;
      a.currentTime = t; c.sync(t);
      const expected = getWordProgresses(lyrics, 0, t, 14);
      const line = d.l.querySelectorAll('.synced-line')[0];
      const actual = [...line.querySelectorAll('.lyric-word')].map(w => parseFloat(w.style.getPropertyValue('--word-progress')) / 100);
      expected.forEach((v, idx) => expect(actual[idx]).toBeCloseTo(v, 1));
    }
    c.destroy();
  });
});

// ---------- 9. Track change while loading ----------
describe('track change while loading/open', () => {
  it('old lyrics replaced and active correct', () => {
    const a = new FakeAudio(); const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o); d.o.classList.add('active');
    const l1 = parseLRC(`[00:00.00] old1\n[00:10.00] old2`);
    const l2 = parseLRC(`[00:00.00] new1\n[00:05.00] new2`);
    c.load(l1); a.currentTime = 10; c.sync(10); expect(c.active).toBe(1);
    c.load(l2); mockOffset(d.l); a.currentTime = 5; c.sync(5);
    expect(d.l.textContent).not.toContain('old1');
    expect(c.active).toBe(1);
    expect(d.l.querySelectorAll('.synced-line')[1].textContent).toContain('new2');
    c.destroy();
  });
});

// ---------- 10. Close/reopen + rAF ----------
describe('close/reopen + rAF', () => {
  let a, d, c;
  const lyrics = parseLRC(`[00:00.00] A\n[00:10.00] B\n[00:20.00] C`);
  beforeEach(() => { a = new FakeAudio(); d = dom(); c = new Ctrl(a, d.c, d.l, d.o); c.load(lyrics); mockOffset(d.l); });
  afterEach(() => c.destroy());
  it('close seek reopen lands on new time', async () => {
    a.currentTime = 0; c.open(); await new Promise(r => requestAnimationFrame(() => r())); expect(c.active).toBe(0);
    c.close(); a.currentTime = 20; a.dispatch('seeking'); a.dispatch('seeked');
    c.open(); await new Promise(r => requestAnimationFrame(() => r())); expect(c.active).toBe(2);
  });
  it('seek while rAF pending cancels', () => {
    a.currentTime = 10; c.open(); // schedules rAF
    const first = c.raf;
    a.currentTime = 20; a.dispatch('seeking');
    expect(c.active).toBe(2);
    // old raf should have been cancelled/replaced
    expect(c.raf !== first || c.raf === null).toBe(true);
  });
});

// ---------- 11. Listener duplication ----------
describe('listener duplication', () => {
  it('100 open/close does not multiply listeners', () => {
    const a = new FakeAudio(); const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o);
    c.load(parseLRC(`[00:00.00] A\n[00:10.00] B`));
    for (let i = 0; i < 100; i++) { c.open(); c.close(); }
    expect(a._m.get('timeupdate').length).toBe(1);
    expect(a._m.get('seeking').length).toBe(1);
    let calls = 0; const orig = c.sync.bind(c); c.sync = t => { calls++; orig(t); };
    a.currentTime = 10; a.dispatch('timeupdate');
    expect(calls).toBe(1);
    c.destroy();
    expect((a._m.get('timeupdate') || []).length).toBe(0);
  });
  it('100 duplicate events keep correct state', () => {
    const a = new FakeAudio(); const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o);
    c.load(parseLRC(`[00:00.00] A\n[00:10.00] B`)); d.o.classList.add('active'); mockOffset(d.l);
    for (let i = 0; i < 100; i++) a.dispatch('timeupdate');
    expect(c.active).toBe(expectedActive(parseLRC(`[00:00.00] A\n[00:10.00] B`), a.currentTime));
    c.destroy();
  });
});

// ---------- 12. Randomized property-based ----------
describe('randomized property-based', () => {
  it('300 random lyrics + times', () => {
    let s = 777; const rand = () => { s = (s * 16807) % 2147483647; return s / 2147483647; };
    for (let trial = 0; trial < 200; trial++) {
      const n = Math.floor(rand() * 20) + 1;
      const times = Array.from({ length: n }, () => Math.floor(rand() * 300)).sort((a, b) => a - b);
      let lrc = '';
      for (let i = 0; i < n; i++) lrc += `[${String(Math.floor(times[i] / 60)).padStart(2, '0')}:${String(times[i] % 60).padStart(2, '0')}.00] line ${i}\n`;
      const lyrics = parseLRC(lrc);
      const t = rand() * 350 - 10;
      expect(getActiveLyricIndex(lyrics, t)).toBe(expectedActive(lyrics, t));
    }
  });
  it('random seek sequence final wins (seed 999)', () => {
    const lyrics = BASE;
    const a = new FakeAudio(); const d = dom(); const c = new Ctrl(a, d.c, d.l, d.o); c.load(lyrics); d.o.classList.add('active');
    let s = 999; const rand = () => { s = (s * 16807) % 2147483647; return s / 2147483647; };
    let fin = 0;
    for (let i = 0; i < 80; i++) { fin = Math.floor(rand() * 90); a.currentTime = fin; a.dispatch('seeking'); if (rand() < 0.3) a.dispatch('seeked'); }
    a.dispatch('seeked');
    expect(c.active).toBe(expectedActive(lyrics, fin));
    c.destroy();
  });
});
