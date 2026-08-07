// ─────────────────────────────────────────────────────────────
// Quaver frontend controller
// ─────────────────────────────────────────────────────────────
//
// Wiring:
//   Tauri IPC → select_music_directory / scan_directory /
//                extract_metadata / load_config / save_config /
//                load_lyrics
//   HTMLAudioElement → playback, seeking, timeupdate
//   LRC parser → drives the synced lyrics view
//
// All IPC calls use camelCase keys; Rust commands use snake_case
// (Tauri auto-converts these at the bridge).
// ─────────────────────────────────────────────────────────────

import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";

// ─────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────
const state = {
  directories: [],          // string[] — registered root paths
  activeDirectory: null,    // string|null
  tracks: [],               // Track[] — current listing
  tracksByPath: new Map(),  // path -> Track (de-duped lookup)
  currentIndex: -1,         // index into `tracks`
  isPlaying: false,
  lyrics: [],               // { time, text }[]
  duration: 0,
};

// ─────────────────────────────────────────────────────────────
// DOM handles
// ─────────────────────────────────────────────────────────────
const $ = (id) => document.getElementById(id);

const ui = {
  directoryList: $("directory-list"),
  addFolderBtn: $("add-folder-btn"),
  addFolderBtnFooter: $("add-folder-btn-footer"),
  trackRows: $("track-rows"),
  backend: $("backdrop"),

  vinyl: $("vinyl"),
  vinylCover: $("vinyl-cover"),
  npTitle: $("np-title"),
  npArtist: $("np-artist"),
  npAlbum: $("np-album"),

  lyricsList: $("lyrics-list"),
  lyricsToggle: $("lyrics-toggle"),

  audio: $("audio"),
  playerCover: $("player-cover"),
  playerTitle: $("player-title"),
  playerArtist: $("player-artist"),
  playBtn: $("play-btn"),
  prevBtn: $("prev-btn"),
  nextBtn: $("next-btn"),
  progress: $("progress"),
  progressFill: $("progress-fill"),
  timeCurrent: $("time-current"),
  timeTotal: $("time-total"),
};

// ─────────────────────────────────────────────────────────────
// IPC wrappers
// ─────────────────────────────────────────────────────────────
async function ipcSelectFolder() {
  return await invoke("select_music_directory");
}

async function ipcScan(path) {
  return await invoke("scan_directory", { path });
}

async function ipcExtractMetadata(paths) {
  return await invoke("extract_metadata", { filePaths: paths });
}

async function ipcLoadConfig() {
  try { return await invoke("load_config"); }
  catch (e) { console.warn("load_config failed:", e); return {}; }
}

async function ipcSaveConfig(config) {
  try { await invoke("save_config", { config }); }
  catch (e) { console.warn("save_config failed:", e); }
}

async function ipcLoadLyrics(path) {
  try {
    return await invoke("load_lyrics", { path });
  } catch (e) {
    console.warn("load_lyrics failed:", e);
    return "";
  }
}

// ─────────────────────────────────────────────────────────────
// Sidebar: directories
// ─────────────────────────────────────────────────────────────
function renderSidebar() {
  ui.directoryList.innerHTML = "";

  if (state.directories.length === 0) {
    const empty = document.createElement("div");
    empty.className = "sidebar__empty";
    empty.innerHTML = `
      <p>No folders yet.</p>
      <button id="add-folder-btn-inline" class="btn btn--primary" type="button">Add Folder</button>
    `;
    ui.directoryList.appendChild(empty);
    empty.querySelector("button").addEventListener("click", onAddFolder);
    return;
  }

  for (const dir of state.directories) {
    const item = document.createElement("div");
    item.className = "sidebar__item";
    if (dir === state.activeDirectory) item.classList.add("sidebar__item--active");
    item.title = dir;
    item.innerHTML = `
      <span class="sidebar__item-icon" aria-hidden="true">♪</span>
      <span class="sidebar__item-name">${escapeHtml(basename(dir))}</span>
      <button class="sidebar__item-remove" type="button" aria-label="Remove">×</button>
    `;
    item.addEventListener("click", (e) => {
      if (e.target.classList.contains("sidebar__item-remove")) return;
      loadDirectory(dir);
    });
    item.querySelector(".sidebar__item-remove").addEventListener("click", (e) => {
      e.stopPropagation();
      removeDirectory(dir);
    });
    ui.directoryList.appendChild(item);
  }
}

async function onAddFolder() {
  const dir = await ipcSelectFolder();
  if (!dir) return;
  if (!state.directories.includes(dir)) {
    state.directories.push(dir);
    await persistConfig();
  }
  await loadDirectory(dir);
}

async function removeDirectory(dir) {
  state.directories = state.directories.filter((d) => d !== dir);
  if (state.activeDirectory === dir) {
    state.activeDirectory = state.directories[0] ?? null;
  }
  await persistConfig();
  if (state.activeDirectory) await loadDirectory(state.activeDirectory);
  else { state.tracks = []; renderSidebar(); renderTrackList(); }
}

// ─────────────────────────────────────────────────────────────
// Track list
// ─────────────────────────────────────────────────────────────
function renderTrackList() {
  ui.trackRows.innerHTML = "";
  if (state.tracks.length === 0) {
    const ph = document.createElement("div");
    ph.className = "tracklist__placeholder";
    ph.innerHTML = "<p>Select a music folder to begin.</p>";
    ui.trackRows.appendChild(ph);
    return;
  }

  for (let i = 0; i < state.tracks.length; i++) {
    const t = state.tracks[i];
    const row = document.createElement("div");
    row.className = "tracklist__row";
    row.role = "listitem";
    if (i === state.currentIndex) row.classList.add("tracklist__row--active");
    row.dataset.index = String(i);
    row.innerHTML = `
      <div class="tracklist__row-title">
        <span class="tracklist__row-icon">${i === state.currentIndex && state.isPlaying ? "♫" : "▸"}</span>
        <span>${escapeHtml(t.title ?? t.file_name)}</span>
      </div>
      <div class="tracklist__row-meta">${escapeHtml(t.artist ?? "—")}</div>
      <div class="tracklist__row-meta">${escapeHtml(t.album ?? "—")}</div>
      <div class="tracklist__row-meta">${formatDuration(t.duration_secs)}</div>
    `;
    row.addEventListener("dblclick", () => playIndex(i));
    row.addEventListener("click", () => selectIndex(i));
    ui.trackRows.appendChild(row);
  }
}

function highlightActiveRow() {
  const rows = ui.trackRows.querySelectorAll(".tracklist__row");
  rows.forEach((r, i) => {
    r.classList.toggle("tracklist__row--active", i === state.currentIndex);
    const icon = r.querySelector(".tracklist__row-icon");
    if (icon) icon.textContent = i === state.currentIndex && state.isPlaying ? "♫" : "▸";
  });
}

function selectIndex(i) {
  state.currentIndex = i;
  highlightActiveRow();
}

async function playIndex(i) {
  if (i < 0 || i >= state.tracks.length) return;
  state.currentIndex = i;
  const track = state.tracks[i];
  highlightActiveRow();

  // Loading state.
  ui.npTitle.textContent = track.title ?? track.file_name;
  ui.npArtist.textContent = track.artist ?? "—";
  ui.npAlbum.textContent = track.album ?? "—";
  ui.playerTitle.textContent = track.title ?? track.file_name;
  ui.playerArtist.textContent = track.artist ?? "—";
  ui.lyricsList.innerHTML = "";

  // Fetch full metadata (cover art + lyric path) for this track.
  try {
    const [meta] = await ipcExtractMetadata([track.path]);
    if (meta) {
      if (meta.cover_art) {
        ui.vinylCover.style.backgroundImage = `url(${meta.cover_art})`;
        ui.playerCover.style.backgroundImage = `url(${meta.cover_art})`;
        applyBackdropFromCover(meta.cover_art);
      } else {
        ui.vinylCover.style.backgroundImage = "";
        ui.playerCover.style.backgroundImage = "";
      }
      if (meta.lyrics_path) {
        const lrc = await ipcLoadLyrics(meta.lyrics_path);
        state.lyrics = parseLrc(lrc);
      } else {
        state.lyrics = [];
      }
      renderLyrics();
    }
  } catch (e) {
    console.warn("metadata load failed:", e);
    state.lyrics = [];
    renderLyrics();
  }

  ui.audio.src = convertFileSrc(track.path);
  try {
    await ui.audio.play();
    setPlaying(true);
  } catch (e) {
    console.warn("play failed:", e);
    setPlaying(false);
  }
}

setInterval(() => {
  if (state.currentIndex < 0) return;
  const track = state.tracks[state.currentIndex];
  if (!track) return;
  if (ui.audio.ended) {
    if (state.currentIndex < state.tracks.length - 1) playIndex(state.currentIndex + 1);
  }
}, 500);

// ─────────────────────────────────────────────────────────────
// Player controls
// ─────────────────────────────────────────────────────────────
function setPlaying(playing) {
  state.isPlaying = playing;
  ui.playBtn.textContent = playing ? "⏸" : "▶";
  ui.playBtn.setAttribute("aria-label", playing ? "Pause" : "Play");
  ui.vinyl.classList.toggle("vinyl--playing", playing);
  highlightActiveRow();
}

ui.playBtn.addEventListener("click", async () => {
  if (state.currentIndex < 0 && state.tracks.length > 0) {
    playIndex(0);
    return;
  }
  if (ui.audio.paused) {
    try { await ui.audio.play(); setPlaying(true); }
    catch (e) { console.warn("play failed:", e); }
  } else {
    ui.audio.pause();
    setPlaying(false);
  }
});

ui.prevBtn.addEventListener("click", () => {
  if (state.currentIndex > 0) playIndex(state.currentIndex - 1);
});

ui.nextBtn.addEventListener("click", () => {
  if (state.currentIndex < state.tracks.length - 1) playIndex(state.currentIndex + 1);
});

ui.audio.addEventListener("timeupdate", () => {
  const t = ui.audio.currentTime || 0;
  const d = ui.audio.duration || 0;
  state.duration = d;
  ui.timeCurrent.textContent = formatTime(t);
  ui.timeTotal.textContent = formatTime(d);
  const pct = d > 0 ? (t / d) * 100 : 0;
  ui.progressFill.style.width = `${pct}%`;
  updateActiveLyric(t);
});

ui.audio.addEventListener("play", () => setPlaying(true));
ui.audio.addEventListener("pause", () => setPlaying(false));
ui.audio.addEventListener("ended", () => {
  if (state.currentIndex < state.tracks.length - 1) playIndex(state.currentIndex + 1);
});

ui.progress.addEventListener("click", (e) => {
  if (!ui.audio.duration) return;
  const rect = ui.progress.getBoundingClientRect();
  const ratio = (e.clientX - rect.left) / rect.width;
  ui.audio.currentTime = ratio * ui.audio.duration;
});

// ─────────────────────────────────────────────────────────────
// Lyrics (.lrc parser + Apple Music-style scroll)
// ─────────────────────────────────────────────────────────────
function parseLrc(text) {
  if (!text) return [];
  const lines = text.split(/\r?\n/);
  const out = [];
  const tagRe = /\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]/;
  for (const raw of lines) {
    const m = raw.match(tagRe);
    if (!m) continue;
    const mins = parseInt(m[1], 10);
    const secs = parseInt(m[2], 10);
    const frac = m[3] ? parseInt(m[3].padEnd(3, "0"), 10) / 1000 : 0;
    const time = mins * 60 + secs + frac;
    const text = raw.replace(tagRe, "").trim();
    if (text) out.push({ time, text });
  }
  out.sort((a, b) => a.time - b.time);
  return out;
}

function renderLyrics() {
  ui.lyricsList.innerHTML = "";
  if (state.lyrics.length === 0) {
    const li = document.createElement("li");
    li.className = "lyrics__line";
    li.textContent = "No synced lyrics for this track.";
    ui.lyricsList.appendChild(li);
    return;
  }
  for (const line of state.lyrics) {
    const li = document.createElement("li");
    li.className = "lyrics__line";
    li.textContent = line.text;
    ui.lyricsList.appendChild(li);
  }
}

let activeLyricIndex = -1;
function updateActiveLyric(t) {
  if (state.lyrics.length === 0) return;
  let next = 0;
  for (let i = 0; i < state.lyrics.length; i++) {
    if (state.lyrics[i].time <= t) next = i;
    else break;
  }
  if (next === activeLyricIndex) return;
  activeLyricIndex = next;

  const items = ui.lyricsList.querySelectorAll(".lyrics__line");
  items.forEach((el, i) => el.classList.toggle("lyrics__line--active", i === next));

  // Apple Music-style scroll: keep the active line centered.
  const activeEl = items[next];
  if (activeEl) {
    const container = ui.lyricsList.parentElement;
    const offset = activeEl.offsetTop - container.clientHeight / 2 + activeEl.clientHeight / 2;
    ui.lyricsList.style.transform = `translateY(${-offset}px)`;
  }
}

ui.lyricsToggle.addEventListener("click", () => {
  document.body.classList.toggle("lyrics-fullscreen");
});

// ─────────────────────────────────────────────────────────────
// Cover-driven backdrop
// ─────────────────────────────────────────────────────────────
function applyBackdropFromCover(dataUrl) {
  // Cheap approach: extract a tiny mid-image and read its median color.
  // For perf, just leave the default mesh — the vinyl + cover carry the brand.
  // Keep this hook in place for future color extraction.
  if (!dataUrl) return;
  const img = new Image();
  img.crossOrigin = "anonymous";
  img.onload = () => {
    try {
      const canvas = document.createElement("canvas");
      const size = 16;
      canvas.width = size; canvas.height = size;
      const ctx = canvas.getContext("2d");
      ctx.drawImage(img, 0, 0, size, size);
      const data = ctx.getImageData(0, 0, size, size).data;
      let r = 0, g = 0, b = 0;
      for (let i = 0; i < data.length; i += 4) {
        r += data[i]; g += data[i + 1]; b += data[i + 2];
      }
      const n = (data.length / 4) || 1;
      r = Math.round(r / n); g = Math.round(g / n); b = Math.round(b / n);
      ui.backend.style.background = `
        radial-gradient(60% 60% at 20% 30%, rgba(${r}, ${g}, ${b}, 0.22), transparent 70%),
        radial-gradient(60% 60% at 80% 70%, rgba(${b}, ${r}, ${g}, 0.18), transparent 70%),
        radial-gradient(50% 50% at 50% 50%, rgba(255, 255, 255, 0.04), transparent 80%),
        var(--bg-window)
      `;
    } catch (e) { /* CORS-blocked canvas read — keep default */ }
  };
  img.src = dataUrl;
}

// ─────────────────────────────────────────────────────────────
// Directory load
// ─────────────────────────────────────────────────────────────
async function loadDirectory(path) {
  state.activeDirectory = path;
  await persistConfig();
  renderSidebar();
  renderTrackList();
  ui.trackRows.innerHTML = `<div class="tracklist__placeholder"><p>Scanning…</p></div>`;
  try {
    const tracks = await ipcScan(path);
    state.tracks = tracks;
    state.tracksByPath = new Map(tracks.map((t) => [t.path, t]));
    renderTrackList();
  } catch (e) {
    console.error("scan failed:", e);
    ui.trackRows.innerHTML = `<div class="tracklist__placeholder"><p>Failed to scan: ${escapeHtml(String(e))}</p></div>`;
  }
}

async function persistConfig() {
  await ipcSaveConfig({
    last_directory: state.activeDirectory,
    directories: state.directories,
    last_track: state.currentIndex >= 0 ? state.tracks[state.currentIndex]?.path ?? null : null,
    last_position_secs: ui.audio.currentTime || 0,
  });
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────
function basename(p) {
  if (!p) return "";
  const parts = p.split(/[\\/]/);
  return parts[parts.length - 1] || p;
}

function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatDuration(secs) {
  if (secs == null || isNaN(secs)) return "—";
  return formatTime(secs);
}

function formatTime(secs) {
  if (!secs || isNaN(secs)) return "0:00";
  const m = Math.floor(secs / 60);
  const s = Math.floor(secs % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

/** Tauri v2 exposes asset URLs via `convertFileSrc` from `@tauri-apps/api/core`. */
function convertFileSrc(p) {
  // We import lazily so the rest of the file works in a plain browser preview.
  return p.startsWith("file://") || p.startsWith("asset:") ? p : `file://${p}`;
}

// ─────────────────────────────────────────────────────────────
// Bootstrap
// ─────────────────────────────────────────────────────────────
async function bootstrap() {
  ui.addFolderBtn?.addEventListener("click", onAddFolder);
  ui.addFolderBtnFooter?.addEventListener("click", onAddFolder);

  const config = await ipcLoadConfig();
  if (config) {
    state.directories = config.directories ?? [];
    if (config.last_directory) {
      await loadDirectory(config.last_directory);
    } else {
      renderSidebar();
    }
  } else {
    renderSidebar();
  }

  // Persist position periodically.
  window.addEventListener("beforeunload", () => { persistConfig(); });
}

// Tauri injects `__TAURI_INTERNALS__` at runtime; we also call the public API.
if (typeof window !== "undefined") {
  bootstrap().catch((e) => console.error("bootstrap failed:", e));
}
