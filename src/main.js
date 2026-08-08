import { formatTime, parseLRC, getNextTrackIndex, getPrevTrackIndex } from './audioUtils.js';

const tauriInvoke = window.__TAURI__?.core?.invoke;
const convertFileSrc = window.__TAURI_INTERNALS__?.convertFileSrc;

function invoke(command, args) {
  if (!tauriInvoke) {
    return Promise.reject(new Error('Tauri API is unavailable'));
  }

  return tauriInvoke(command, args);
}

// State
let playlist = [];
let currentTrackIndex = -1;
let isPlaying = false;
let isShuffle = false;
let repeatMode = 'off';
let playbackQueue = [];
let queueDragIndex = null;
let playbackSpeedIndex = 0;
const playbackSpeeds = [1, 1.25, 1.5, 2];
let lyrics = [];
let activeLyricIndex = -1;
let lastPlaybackErrorSource = '';
let songSearchQuery = '';
let libraryView = { type: 'all', value: null };
let librarySort = 'title';
let libraryFilter = 'all';
let customPlaylists = loadLibraryData('quaver-playlists', []);
let likedTrackKeys = new Set(loadLibraryData('quaver-liked-tracks', []));
let recentlyPlayed = loadLibraryData('quaver-recently-played', []);
let lyricsManualScrollUntil = 0;
let lyricsDragState = null;
let wasLyricsDragged = false;
let lyricsScrollAnimationId = null;

const audio = new Audio();
audio.volume = 0.8;
audio.preload = 'metadata';
const nextTrackPreloader = new Audio();
nextTrackPreloader.preload = 'auto';
let preloadedTrackIndex = -1;

// DOM Elements
const importBtn = document.getElementById('import-folder-btn');
const fallbackFolderInput = document.getElementById('fallback-folder-input');
const tracksListBody = document.getElementById('tracks-list-body');
const songSearchInput = document.getElementById('song-search-input');
const libraryViewTitle = document.getElementById('library-view-title');
const libraryEyebrow = document.getElementById('library-eyebrow');
const libraryFilterSelect = document.getElementById('library-filter-select');
const librarySortSelect = document.getElementById('library-sort-select');
const playlistNavList = document.getElementById('playlist-nav-list');

// Mini Player Controls
const miniCover = document.getElementById('mini-cover');
const miniTitle = document.getElementById('mini-title');
const miniArtist = document.getElementById('mini-artist');
const playBtn = document.getElementById('btn-play');
const playIcon = document.getElementById('play-icon');
const prevBtn = document.getElementById('btn-prev');
const nextBtn = document.getElementById('btn-next');
const shuffleBtn = document.getElementById('btn-shuffle');
const repeatBtn = document.getElementById('btn-repeat');
const progressBarWrapper = document.getElementById('progress-bar-wrapper');
const progressBar = document.getElementById('progress-bar');
const timeElapsed = document.getElementById('time-elapsed');
const timeTotal = document.getElementById('time-total');
const volumeBarWrapper = document.getElementById('volume-bar-wrapper');
const volumeBar = document.getElementById('volume-bar');
const lyricsToggleBtn = document.getElementById('btn-lyrics-toggle');
const queueBtn = document.getElementById('btn-queue');
const speedBtn = document.getElementById('btn-speed');
const queuePanel = document.getElementById('queue-panel');
const queueList = document.getElementById('queue-list');
const closeQueueBtn = document.getElementById('btn-close-queue');

// Fullscreen Controls
const fullscreenOverlay = document.getElementById('fullscreen-overlay');
const fsBg = document.getElementById('fullscreen-bg');
const fsWindowTitle = document.getElementById('fs-window-title');
const btnCloseFs = document.getElementById('btn-close-fs');
const fsCoverImage = document.getElementById('fullscreen-cover-image');
const fsTrackTitle = document.getElementById('fullscreen-track-title');
const fsTrackArtist = document.getElementById('fullscreen-track-artist');
const fsProgressBarWrapper = document.getElementById('fs-progress-bar-wrapper');
const fsProgressBar = document.getElementById('fs-progress-bar');
const fsTimeElapsed = document.getElementById('fs-time-elapsed');
const fsTimeTotal = document.getElementById('fs-time-total');
const fsPlayBtn = document.getElementById('fs-btn-play');
const fsPlayIcon = document.getElementById('fs-play-icon');
const fsPrevBtn = document.getElementById('fs-btn-prev');
const fsNextBtn = document.getElementById('fs-btn-next');
const fsShuffleBtn = document.getElementById('fs-btn-shuffle');
const fsRepeatBtn = document.getElementById('fs-btn-repeat');
const fsVolumeBarWrapper = document.getElementById('fs-volume-bar-wrapper');
const fsVolumeBar = document.getElementById('fs-volume-bar');
const syncedLyricsList = document.getElementById('synced-lyrics-list');
const lyricsContainer = document.getElementById('fullscreen-lyrics-container');
const sidebarTracks = document.getElementById('sidebar-tracks');
const sidebarNowPlaying = document.getElementById('sidebar-nowplaying');
const sidebarLiked = document.getElementById('sidebar-liked');
const sidebarRecent = document.getElementById('sidebar-recent');
const sidebarArtists = document.getElementById('sidebar-artists');
const sidebarAlbums = document.getElementById('sidebar-albums');
const createPlaylistBtn = document.getElementById('create-playlist-btn');

function loadLibraryData(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
}

function saveLibraryData(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* local storage is optional */ }
}

function trackKey(track) {
  return String(track?.path || `${track?.title}|${track?.artist}|${track?.album}`);
}

// Direct Native Rust Folder Picker Handler
async function handleSelectFolder(e) {
  if (e) {
    e.preventDefault();
    e.stopPropagation();
  }

  if (!tauriInvoke) {
    fallbackFolderInput.click();
    return;
  }

  try {
    const folderPath = await invoke('select_folder');
    if (folderPath && typeof folderPath === 'string') {
      scanFolder(folderPath);
    }
  } catch (err) {
    console.error('Rust select_folder failed:', err);
    alert('Could not open the native folder picker. Please restart the app and try again.');
  }
}

// Bind Folder Buttons
if (importBtn) {
  importBtn.addEventListener('click', handleSelectFolder);
}

function bindEmptyStateButton() {
  const emptyBtn = document.getElementById('empty-add-folder-btn');
  if (emptyBtn) {
    emptyBtn.addEventListener('click', handleSelectFolder);
  }
}
bindEmptyStateButton();

// Fallback HTML5 folder input change handler
fallbackFolderInput.addEventListener('change', (event) => {
  const files = Array.from(event.target.files);
  const audioFiles = files.filter(file => 
    /\.(flac|m4a|alac|mp3|aac|wav|aiff|aif|ogg|opus|wma|ape|ac3|mka)$/i.test(file.name)
  );

  if (audioFiles.length === 0) {
    alert('No supported audio files found in selected folder.');
    return;
  }

  playlist = audioFiles.map((file, idx) => ({
    id: idx,
    path: URL.createObjectURL(file),
    title: file.name.replace(/\.[^/.]+$/, ''),
    artist: 'Local Artist',
    album: 'Local Album',
    duration: 0,
    format: file.name.split('.').pop().toUpperCase(),
    cover: '',
    lyricPath: null
  }));

  renderPlaylist();
});

// Invoke Rust Backend to Scan Directory
async function scanFolder(folderPath) {
  tracksListBody.innerHTML = `
    <tr>
      <td colspan="5" style="text-align: center; padding: 4rem 1rem;">
        <div class="empty-icon">⚡</div>
        <h3>Indexing folder with Rust core...</h3>
        <p>Parsing audio metadata high-speed.</p>
      </td>
    </tr>
  `;

  try {
    const results = await invoke('scan_directory', { dirPath: folderPath });
    playlist = results.map((item, idx) => ({
      id: idx,
      path: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: item.duration,
      format: item.format,
      cover: item.cover_data_url || '',
      lyricPath: item.lyric_path || null
    }));

    renderPlaylist();
  } catch (err) {
    console.error('Error scanning folder:', err);
    alert('Failed to scan directory: ' + err);
  }
}

async function restoreSavedLibrary() {
  if (!tauriInvoke) return;

  try {
    const folderPath = await invoke('get_saved_music_folder');
    if (folderPath) {
      scanFolder(folderPath);
    }
  } catch (error) {
    // A missing or unplugged external drive should not stop the app from opening.
    console.warn('Could not restore saved music folder:', error);
  }
}

function renderPlaylist() {
  if (playlist.length === 0) {
    tracksListBody.innerHTML = `
      <tr class="empty-state">
        <td colspan="5" style="text-align: center; padding: 5rem 1rem;">
          <div class="empty-icon">📁</div>
          <h3>No music loaded yet</h3>
          <p>Select your FLAC/ALAC library folder from your local disk or external hard drive.</p>
          <div style="display: flex; justify-content: center; margin-top: 16px;">
            <button id="empty-add-folder-btn" class="btn-primary-mac" style="padding: 10px 20px; font-size: 14px;">
              <svg class="icon-svg" viewBox="0 0 24 24" style="width: 18px; height: 18px;"><path fill="currentColor" d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>
              Select Music Folder
            </button>
          </div>
        </td>
      </tr>
    `;
    bindEmptyStateButton();
    return;
  }

  updateLibraryHeading();
  if (libraryView.type === 'artists' || libraryView.type === 'albums') {
    renderBrowseGroups(libraryView.type);
    return;
  }

  const normalizedQuery = songSearchQuery.trim().toLocaleLowerCase();
  let visibleTracks = playlist
    .map((track, index) => ({ track, index }))
    .filter(({ track }) => isInCurrentLibraryView(track))
    .filter(({ track }) => !normalizedQuery || [track.title, track.artist, track.album, track.format]
      .some((value) => String(value || '').toLocaleLowerCase().includes(normalizedQuery)))
    .filter(({ track }) => matchesLibraryFilter(track));

  visibleTracks = sortVisibleTracks(visibleTracks);

  if (visibleTracks.length === 0) {
    tracksListBody.innerHTML = `
      <tr class="empty-state search-empty-state">
        <td colspan="5" style="text-align: center; padding: 5rem 1rem;">
          <div class="empty-icon">⌕</div>
          <h3>No songs found</h3>
          <p>No songs match “${escapeHtml(songSearchQuery.trim())}”.</p>
          <button id="clear-song-search-btn" class="btn-secondary-mac">Clear search</button>
        </td>
      </tr>
    `;
    document.getElementById('clear-song-search-btn')?.addEventListener('click', clearSongSearch);
    return;
  }

  tracksListBody.innerHTML = '';
  visibleTracks.forEach(({ track, index }) => {
    const row = document.createElement('tr');
    if (index === currentTrackIndex) {
      row.classList.add('playing');
    }

    row.addEventListener('click', () => {
      playTrack(index);
    });

    const isLiked = likedTrackKeys.has(trackKey(track));
    row.innerHTML = `
      <td class="col-num">${index + 1}</td>
      <td class="col-title">
        <div class="track-cell">
          ${track.cover ? `<img src="${track.cover}" style="width: 28px; height: 28px; border-radius: 4px; object-fit: cover;" />` : `<div style="width: 28px; height: 28px; border-radius: 4px; background-color:#27272a;"></div>`}
          <div>${escapeHtml(track.title)}</div>
          <button class="like-track-btn ${isLiked ? 'liked' : ''}" title="${isLiked ? 'Remove from Liked Songs' : 'Add to Liked Songs'}" aria-label="Like ${escapeHtml(track.title)}">${isLiked ? '♥' : '♡'}</button>
          <button class="add-to-playlist-btn" title="Add to playlist" aria-label="Add ${escapeHtml(track.title)} to playlist">＋</button>
        </div>
      </td>
      <td class="col-album">${escapeHtml(track.album)}</td>
      <td class="col-type"><span style="background-color:#27272a; padding: 2px 6px; border-radius:4px; font-size:11px;">${track.format}</span></td>
      <td class="col-duration">${formatTime(track.duration)}</td>
    `;
    row.querySelector('.like-track-btn').addEventListener('click', (event) => {
      event.stopPropagation();
      toggleLikedTrack(track);
    });
    row.querySelector('.add-to-playlist-btn').addEventListener('click', (event) => {
      event.stopPropagation();
      addTrackToPlaylist(track);
    });
    tracksListBody.appendChild(row);
  });
}

function isInCurrentLibraryView(track) {
  if (libraryView.type === 'liked') return likedTrackKeys.has(trackKey(track));
  if (libraryView.type === 'recent') return recentlyPlayed.some((item) => item.key === trackKey(track));
  if (libraryView.type === 'playlist') return (libraryView.value?.trackKeys || []).includes(trackKey(track));
  if (libraryView.type === 'artist') return track.artist === libraryView.value;
  if (libraryView.type === 'album') return track.album === libraryView.value;
  return true;
}

function matchesLibraryFilter(track) {
  const format = String(track.format || '').toLowerCase();
  if (libraryFilter === 'flac') return format === 'flac';
  if (libraryFilter === 'lossless') return ['flac', 'alac', 'wav', 'aiff', 'aif'].includes(format);
  return true;
}

function sortVisibleTracks(items) {
  if (libraryView.type === 'recent') {
    return items.sort((a, b) => (recentlyPlayed.find((item) => item.key === trackKey(b.track))?.playedAt || 0) - (recentlyPlayed.find((item) => item.key === trackKey(a.track))?.playedAt || 0));
  }
  const field = librarySort;
  if (field === 'recent') {
    return items.sort((a, b) => playlist.indexOf(b.track) - playlist.indexOf(a.track));
  }
  return items.sort((a, b) => String(a.track[field] || '').localeCompare(String(b.track[field] || ''), undefined, { sensitivity: 'base' }));
}

function updateLibraryHeading() {
  const labels = { all: 'All Songs', liked: 'Liked Songs', recent: 'Recently Played', artists: 'Artists', albums: 'Albums', artist: libraryView.value, album: libraryView.value, playlist: libraryView.value?.name };
  libraryViewTitle.textContent = labels[libraryView.type] || 'Library';
  libraryEyebrow.textContent = libraryView.type === 'playlist' ? 'Playlist' : libraryView.type === 'artist' || libraryView.type === 'album' ? 'Browse' : 'Library';
}

function toggleLikedTrack(track) {
  const key = trackKey(track);
  likedTrackKeys.has(key) ? likedTrackKeys.delete(key) : likedTrackKeys.add(key);
  saveLibraryData('quaver-liked-tracks', [...likedTrackKeys]);
  renderPlaylist();
}

function addTrackToPlaylist(track) {
  if (!customPlaylists.length) {
    const shouldCreate = window.confirm('Create a playlist first?');
    if (shouldCreate) createPlaylist();
    return;
  }
  const choices = customPlaylists.map((item, index) => `${index + 1}. ${item.name}`).join('\n');
  const selection = Number(window.prompt(`Add to which playlist?\n${choices}`));
  const target = customPlaylists[selection - 1];
  if (!target) return;
  const key = trackKey(track);
  if (!target.trackKeys.includes(key)) target.trackKeys.push(key);
  saveLibraryData('quaver-playlists', customPlaylists);
  if (libraryView.type === 'playlist') renderPlaylist();
}

function renderBrowseGroups(type) {
  const field = type === 'artists' ? 'artist' : 'album';
  const groups = [...new Map(playlist.map((track) => [track[field] || `Unknown ${type === 'artists' ? 'Artist' : 'Album'}`, null])).keys()]
    .filter((name) => !songSearchQuery.trim() || name.toLowerCase().includes(songSearchQuery.trim().toLowerCase()))
    .sort((a, b) => a.localeCompare(b));
  tracksListBody.innerHTML = '';
  if (!groups.length) {
    tracksListBody.innerHTML = '<tr class="empty-state"><td colspan="5" style="text-align:center; padding:5rem 1rem;"><h3>Nothing to browse yet</h3><p>Add a music folder to build your library.</p></td></tr>';
    return;
  }
  groups.forEach((name, groupIndex) => {
    const tracks = playlist.filter((track) => (track[field] || `Unknown ${type === 'artists' ? 'Artist' : 'Album'}`) === name);
    const row = document.createElement('tr');
    row.className = 'browse-row';
    row.innerHTML = `<td class="col-num">${groupIndex + 1}</td><td class="col-title"><div class="browse-name">${escapeHtml(name)}<span>${tracks.length} song${tracks.length === 1 ? '' : 's'}</span></div></td><td class="col-album">${type === 'albums' ? escapeHtml(tracks[0]?.artist || 'Unknown Artist') : ''}</td><td class="col-type">Browse</td><td class="col-duration">›</td>`;
    row.addEventListener('click', () => setLibraryView(type === 'artists' ? 'artist' : 'album', name));
    tracksListBody.appendChild(row);
  });
}

function ensureQueue(index = currentTrackIndex) {
  if (playlist.length === 0) return;
  if (playbackQueue.length === 0 || !playbackQueue.every((item) => playlist[item])) {
    playbackQueue = [...Array(playlist.length).keys()];
  }
  if (index >= 0 && !playbackQueue.includes(index)) playbackQueue.unshift(index);
}

function renderQueue() {
  if (!queueList) return;
  ensureQueue();
  queueList.innerHTML = '';
  if (playbackQueue.length === 0) {
    queueList.innerHTML = '<p class="queue-empty">Your queue will appear here.</p>';
    return;
  }

  playbackQueue.forEach((trackIndex, queueIndex) => {
    const track = playlist[trackIndex];
    if (!track) return;
    const item = document.createElement('button');
    item.type = 'button';
    item.className = `queue-item${trackIndex === currentTrackIndex ? ' current' : ''}`;
    item.draggable = true;
    item.innerHTML = `<span class="queue-drag" aria-hidden="true">⠿</span><span class="queue-item-art">${track.cover ? `<img src="${track.cover}" alt="" />` : ''}</span><span class="queue-item-meta"><strong>${escapeHtml(track.title)}</strong><small>${escapeHtml(track.artist)}</small></span><span class="queue-item-more">⋯</span>`;
    item.addEventListener('click', () => playTrack(trackIndex));
    item.addEventListener('dragstart', (event) => {
      queueDragIndex = queueIndex;
      item.classList.add('dragging');
      event.dataTransfer.effectAllowed = 'move';
    });
    item.addEventListener('dragend', () => { queueDragIndex = null; item.classList.remove('dragging'); });
    item.addEventListener('dragover', (event) => event.preventDefault());
    item.addEventListener('drop', (event) => {
      event.preventDefault();
      if (queueDragIndex === null || queueDragIndex === queueIndex) return;
      const [moved] = playbackQueue.splice(queueDragIndex, 1);
      playbackQueue.splice(queueIndex, 0, moved);
      renderQueue();
    });
    queueList.appendChild(item);
  });
}

function setRepeatMode(mode) {
  repeatMode = mode;
  const isOn = mode !== 'off';
  [repeatBtn, fsRepeatBtn].forEach((button) => {
    button.classList.toggle('active', isOn);
    button.classList.toggle('repeat-one', mode === 'one');
    button.title = mode === 'one' ? 'Repeat one' : mode === 'all' ? 'Repeat all' : 'Repeat off';
  });
}

function cycleRepeat() {
  setRepeatMode(repeatMode === 'off' ? 'all' : repeatMode === 'all' ? 'one' : 'off');
}

function cyclePlaybackSpeed() {
  playbackSpeedIndex = (playbackSpeedIndex + 1) % playbackSpeeds.length;
  audio.playbackRate = playbackSpeeds[playbackSpeedIndex];
  speedBtn.textContent = `${playbackSpeeds[playbackSpeedIndex]}×`;
  speedBtn.classList.toggle('active', playbackSpeeds[playbackSpeedIndex] !== 1);
}

function escapeHtml(value) {
  const element = document.createElement('div');
  element.textContent = value;
  return element.innerHTML;
}

function clearSongSearch() {
  songSearchQuery = '';
  songSearchInput.value = '';
  songSearchInput.focus();
  renderPlaylist();
}

songSearchInput.addEventListener('input', (event) => {
  songSearchQuery = event.target.value;
  renderPlaylist();
});

songSearchInput.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && songSearchQuery) {
    event.preventDefault();
    clearSongSearch();
  }
});

function setLibraryView(type, value = null) {
  libraryView = { type, value: type === 'playlist' ? customPlaylists.find((item) => item.id === value) : value };
  document.querySelectorAll('.sidebar-item').forEach((item) => item.classList.remove('active'));
  const navId = { all: 'sidebar-tracks', liked: 'sidebar-liked', recent: 'sidebar-recent', artists: 'sidebar-artists', albums: 'sidebar-albums' }[type];
  (navId ? document.getElementById(navId) : document.querySelector(`[data-playlist-id="${value}"]`))?.classList.add('active');
  renderPlaylist();
}

function renderPlaylistNavigation() {
  playlistNavList.innerHTML = '';
  customPlaylists.forEach((item) => {
    const link = document.createElement('a');
    link.href = '#';
    link.className = 'sidebar-item playlist-nav-item';
    link.dataset.playlistId = item.id;
    link.innerHTML = `<span class="playlist-note">♫</span><span>${escapeHtml(item.name)}</span>`;
    link.addEventListener('click', (event) => { event.preventDefault(); setLibraryView('playlist', item.id); });
    playlistNavList.appendChild(link);
  });
}

function createPlaylist() {
  const name = window.prompt('Name your new playlist');
  if (!name?.trim()) return;
  customPlaylists.push({ id: crypto.randomUUID?.() || `${Date.now()}`, name: name.trim(), trackKeys: [] });
  saveLibraryData('quaver-playlists', customPlaylists);
  renderPlaylistNavigation();
  setLibraryView('playlist', customPlaylists.at(-1).id);
}

function recordRecentlyPlayed(track) {
  const key = trackKey(track);
  recentlyPlayed = [{ key, playedAt: Date.now() }, ...recentlyPlayed.filter((item) => item.key !== key)].slice(0, 50);
  saveLibraryData('quaver-recently-played', recentlyPlayed);
}

libraryFilterSelect?.addEventListener('change', (event) => { libraryFilter = event.target.value; renderPlaylist(); });
librarySortSelect?.addEventListener('change', (event) => { librarySort = event.target.value; renderPlaylist(); });
sidebarLiked?.addEventListener('click', (event) => { event.preventDefault(); setLibraryView('liked'); });
sidebarRecent?.addEventListener('click', (event) => { event.preventDefault(); setLibraryView('recent'); });
sidebarArtists?.addEventListener('click', (event) => { event.preventDefault(); setLibraryView('artists'); });
sidebarAlbums?.addEventListener('click', (event) => { event.preventDefault(); setLibraryView('albums'); });
createPlaylistBtn?.addEventListener('click', createPlaylist);
renderPlaylistNavigation();

function getTrackSource(track) {
  if (track.path.startsWith('blob:')) {
    return track.path;
  }

  if (!convertFileSrc) {
    throw new Error('Native file playback is unavailable outside the Quaver desktop app.');
  }

  return convertFileSrc(track.path);
}

function showPlaybackError(error) {
  const failedSource = audio.currentSrc;
  if (failedSource && failedSource === lastPlaybackErrorSource) {
    return;
  }

  lastPlaybackErrorSource = failedSource;
  console.error('Audio playback failed:', error);
  isPlaying = false;
  updatePlayButtonUI();
  alert(`Could not play this track. ${error.message || 'Its format may not be supported by this device.'}`);
}

// Play track by index
async function playTrack(index) {
  if (index < 0 || index >= playlist.length) return;

  ensureQueue(index);
  currentTrackIndex = index;
  const track = playlist[currentTrackIndex];
  recordRecentlyPlayed(track);
  renderPlaylist();

  try {
    lastPlaybackErrorSource = '';
    audio.src = getTrackSource(track);
    audio.load();
    await audio.play();
  } catch (error) {
    showPlaybackError(error);
    return;
  }

  let hasLyrics = false;
  if (track.lyricPath) {
    try {
      const lrcText = await invoke('read_lyrics_file', { filePath: track.lyricPath });
      lyrics = parseLRC(lrcText);
      hasLyrics = lyrics.length > 0;
    } catch {
      lyrics = [];
      hasLyrics = false;
    }
  } else {
    lyrics = [];
    hasLyrics = false;
  }
  activeLyricIndex = -1;
  renderLyrics();
  fullscreenOverlay.classList.toggle('no-lyrics', !hasLyrics);

  miniTitle.textContent = track.title;
  miniArtist.textContent = track.artist;
  miniCover.style.backgroundImage = track.cover ? `url(${track.cover})` : 'none';

  fsWindowTitle.textContent = `Quaver - ${track.title} • ${track.artist} 🔊`;
  fsTrackTitle.textContent = track.title;
  fsTrackArtist.textContent = track.artist;
  fsCoverImage.style.backgroundImage = track.cover ? `url(${track.cover})` : 'none';
  fsBg.style.backgroundImage = track.cover ? `url(${track.cover})` : 'none';
  
  const fsCard = document.querySelector('.fullscreen-artwork-card');
  if (fsCard) fsCard.classList.add('playing');
  renderQueue();
  updateMediaSession(track);
}

function updateMediaSession(track) {
  if (!('mediaSession' in navigator)) return;
  navigator.mediaSession.metadata = new MediaMetadata({
    title: track.title || 'Unknown title', artist: track.artist || 'Unknown artist', album: track.album || '',
    artwork: track.cover ? [{ src: track.cover, sizes: '512x512', type: 'image/*' }] : []
  });
}

function generateMockLyrics(track) {
  return [
    { time: 0, text: `🎶 Playing: ${track.title}` },
    { time: 3, text: `Artist: ${track.artist}` },
    { time: 6, text: `Album: ${track.album}` },
    { time: 9, text: `[High-fidelity ${track.format} audio parsed natively]` },
    { time: 15, text: `Add a matching .lrc file in your music folder` },
    { time: 20, text: `with the exact same name as the audio file` },
    { time: 25, text: `to display beautiful scrolling synced lyrics.` },
  ];
}

function renderLyrics() {
  syncedLyricsList.innerHTML = '';
  if (lyrics.length === 0) {
    syncedLyricsList.innerHTML = '<div class="lyrics-placeholder">No lyrics loaded</div>';
    return;
  }

  lyrics.forEach((line, index) => {
    const div = document.createElement('div');
    div.className = 'synced-line';
    line.text.split(/(\s+)/).forEach((part) => {
      if (/^\s+$/.test(part)) {
        div.append(document.createTextNode(part));
        return;
      }

      const word = document.createElement('span');
      word.className = 'lyric-word';
      word.textContent = part;
      word.style.setProperty('--word-progress', '0%');
      div.append(word);
    });

    syncedLyricsList.appendChild(div);
  });
}

function getLyricLineDuration(index) {
  const nextTimestamp = Number.isFinite(lyrics[index + 1]?.time)
    ? lyrics[index + 1].time
    : (Number.isFinite(audio.duration) ? audio.duration : lyrics[index].time + 4);
  return Math.max(0.6, nextTimestamp - lyrics[index].time);
}

function seekToLyricWord(lineIndex, wordIndex, wordCount) {
  const wordFraction = wordIndex / Math.max(1, wordCount);
  audio.currentTime = lyrics[lineIndex].time + getLyricLineDuration(lineIndex) * wordFraction;
  lyricsManualScrollUntil = 0;
  syncLyrics(audio.currentTime);
}

function seekFromLyricTarget(target) {
  const lyricLine = target instanceof Element ? target.closest('.synced-line') : null;
  if (!lyricLine) return;

  const lines = [...syncedLyricsList.querySelectorAll('.synced-line')];
  const lineIndex = lines.indexOf(lyricLine);
  if (lineIndex < 0) return;

  const lyricWord = target.closest?.('.lyric-word');
  if (lyricWord) {
    const words = [...lyricLine.querySelectorAll('.lyric-word')];
    seekToLyricWord(lineIndex, words.indexOf(lyricWord), words.length);
    return;
  }

  audio.currentTime = lyrics[lineIndex].time;
  lyricsManualScrollUntil = 0;
  syncLyrics(audio.currentTime);
}

function syncLyrics(currentTime) {
  if (lyrics.length === 0) return;

  let activeIndex = -1;
  for (let i = 0; i < lyrics.length; i++) {
    if (currentTime >= lyrics[i].time) {
      activeIndex = i;
    } else {
      break;
    }
  }

  if (activeIndex !== activeLyricIndex) {
    activeLyricIndex = activeIndex;
    const lines = syncedLyricsList.querySelectorAll('.synced-line');
    
    lines.forEach((line, index) => {
      line.classList.remove('active', 'past', 'upcoming', 'nearby');
      if (index === activeIndex) {
        line.classList.add('active');
        if (Date.now() >= lyricsManualScrollUntil) {
          const containerHeight = lyricsContainer.clientHeight;
          const lineOffsetTop = line.offsetTop;
          const lineLimit = lineOffsetTop - containerHeight / 2 + line.clientHeight / 2;
          smoothlyCenterLyric(Math.max(0, lineLimit));
        }
      } else if (index < activeIndex) {
        line.classList.add('past');
      } else {
        line.classList.add('upcoming');
      }

      if (Math.abs(index - activeIndex) === 1) {
        line.classList.add('nearby');
      }
    });
  }

  updateLyricWordProgress(activeIndex, currentTime);
}

function updateLyricWordProgress(index, currentTime) {
  if (index < 0) return;

  const line = syncedLyricsList.querySelectorAll('.synced-line')[index];
  if (!line) return;

  const lineDuration = getLyricLineDuration(index);
  const lineProgress = Math.max(0, Math.min(1, (currentTime - lyrics[index].time) / lineDuration));
  const words = line.querySelectorAll('.lyric-word');

  words.forEach((word, wordIndex) => {
    const wordProgress = Math.max(0, Math.min(1, lineProgress * words.length - wordIndex));
    word.style.setProperty('--word-progress', `${wordProgress * 100}%`);
  });
}

function smoothlyCenterLyric(targetTop) {
  if (lyricsScrollAnimationId) {
    window.cancelAnimationFrame(lyricsScrollAnimationId);
  }

  const startTop = lyricsContainer.scrollTop;
  const distance = targetTop - startTop;
  const duration = 720;
  const startedAt = performance.now();

  function step(now) {
    const progress = Math.min(1, (now - startedAt) / duration);
    const easedProgress = 1 - Math.pow(1 - progress, 4);
    lyricsContainer.scrollTop = startTop + distance * easedProgress;

    if (progress < 1) {
      lyricsScrollAnimationId = window.requestAnimationFrame(step);
    } else {
      lyricsScrollAnimationId = null;
    }
  }

  lyricsScrollAnimationId = window.requestAnimationFrame(step);
}

function pauseLyricsAutoscroll() {
  lyricsManualScrollUntil = Date.now() + 4500;
  if (lyricsScrollAnimationId) {
    window.cancelAnimationFrame(lyricsScrollAnimationId);
    lyricsScrollAnimationId = null;
  }
}

lyricsContainer.addEventListener('wheel', pauseLyricsAutoscroll, { passive: true });
lyricsContainer.addEventListener('touchstart', pauseLyricsAutoscroll, { passive: true });

lyricsContainer.addEventListener('pointerdown', (event) => {
  if (event.pointerType === 'mouse' && event.button !== 0) return;

  lyricsDragState = {
    pointerId: event.pointerId,
    startY: event.clientY,
    startScrollTop: lyricsContainer.scrollTop,
    moved: false,
    pressTarget: event.target
  };
  lyricsContainer.setPointerCapture?.(event.pointerId);
});

lyricsContainer.addEventListener('pointermove', (event) => {
  if (!lyricsDragState || event.pointerId !== lyricsDragState.pointerId) return;

  const distance = event.clientY - lyricsDragState.startY;
  if (Math.abs(distance) > 3) {
    lyricsDragState.moved = true;
    pauseLyricsAutoscroll();
    lyricsContainer.scrollTop = lyricsDragState.startScrollTop - distance;
    event.preventDefault();
  }
});

function finishLyricsDrag(event) {
  if (!lyricsDragState || event.pointerId !== lyricsDragState.pointerId) return;
  wasLyricsDragged = lyricsDragState.moved;
  if (wasLyricsDragged) {
    pauseLyricsAutoscroll();
    window.setTimeout(() => { wasLyricsDragged = false; }, 0);
  } else {
    // Pointer capture makes pointerup target the container, so use the original
    // element pressed to reliably seek when tapping a lyric or individual word.
    seekFromLyricTarget(lyricsDragState.pressTarget);
  }
  lyricsDragState = null;
}

lyricsContainer.addEventListener('pointerup', finishLyricsDrag);
lyricsContainer.addEventListener('pointercancel', finishLyricsDrag);

function togglePlay() {
  if (playlist.length === 0) return;
  if (currentTrackIndex === -1) {
    playTrack(0);
    return;
  }

  if (isPlaying) {
    audio.pause();
  } else {
    audio.play().catch(showPlaybackError);
  }
}

function updatePlayButtonUI() {
  if (isPlaying) {
    playIcon.innerHTML = `<path fill="currentColor" d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/>`;
    fsPlayIcon.innerHTML = `<path fill="currentColor" d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/>`;
  } else {
    playIcon.innerHTML = `<path fill="currentColor" d="M8 5v14l11-7z"/>`;
    fsPlayIcon.innerHTML = `<path fill="currentColor" d="M8 5v14l11-7z"/>`;
  }
}

function playNext() {
  if (playlist.length === 0) return;
  ensureQueue();
  const queuePosition = playbackQueue.indexOf(currentTrackIndex);
  if (!isShuffle && queuePosition >= 0 && queuePosition < playbackQueue.length - 1) {
    playTrack(playbackQueue[queuePosition + 1]);
    return;
  }
  if (repeatMode === 'all' || isShuffle) {
    playTrack(getNextTrackIndex(currentTrackIndex, playlist.length, isShuffle));
  } else {
    audio.pause();
    audio.currentTime = 0;
  }
}

function preloadUpcomingTrack() {
  if (playlist.length === 0 || isShuffle) return;
  ensureQueue();
  const position = playbackQueue.indexOf(currentTrackIndex);
  const nextIndex = playbackQueue[position + 1];
  if (nextIndex === undefined || nextIndex === preloadedTrackIndex) return;
  try {
    nextTrackPreloader.src = getTrackSource(playlist[nextIndex]);
    nextTrackPreloader.load();
    preloadedTrackIndex = nextIndex;
  } catch { /* Preloading is an optional enhancement. */ }
}

function playPrev() {
  if (playlist.length === 0) return;
  ensureQueue();
  const queuePosition = playbackQueue.indexOf(currentTrackIndex);
  if (!isShuffle && queuePosition > 0) playTrack(playbackQueue[queuePosition - 1]);
  else playTrack(getPrevTrackIndex(currentTrackIndex, playlist.length));
}

// Controls
playBtn.addEventListener('click', togglePlay);
fsPlayBtn.addEventListener('click', togglePlay);
prevBtn.addEventListener('click', playPrev);
fsPrevBtn.addEventListener('click', playPrev);
nextBtn.addEventListener('click', playNext);
fsNextBtn.addEventListener('click', playNext);

shuffleBtn.addEventListener('click', () => {
  isShuffle = !isShuffle;
  shuffleBtn.classList.toggle('active', isShuffle);
  fsShuffleBtn.classList.toggle('active', isShuffle);
});
fsShuffleBtn.addEventListener('click', () => {
  isShuffle = !isShuffle;
  shuffleBtn.classList.toggle('active', isShuffle);
  fsShuffleBtn.classList.toggle('active', isShuffle);
});

repeatBtn.addEventListener('click', cycleRepeat);
fsRepeatBtn.addEventListener('click', cycleRepeat);
speedBtn.addEventListener('click', cyclePlaybackSpeed);
queueBtn.addEventListener('click', () => {
  renderQueue();
  queuePanel.classList.add('open');
  queuePanel.setAttribute('aria-hidden', 'false');
});
closeQueueBtn.addEventListener('click', () => {
  queuePanel.classList.remove('open');
  queuePanel.setAttribute('aria-hidden', 'true');
});

audio.addEventListener('timeupdate', () => {
  const percent = (audio.currentTime / audio.duration) * 100 || 0;
  progressBar.style.width = `${percent}%`;
  fsProgressBar.style.width = `${percent}%`;
  timeElapsed.textContent = formatTime(audio.currentTime);
  fsTimeElapsed.textContent = formatTime(audio.currentTime);
  syncLyrics(audio.currentTime);
  if (Number.isFinite(audio.duration) && audio.duration - audio.currentTime < 12) preloadUpcomingTrack();
  if ('mediaSession' in navigator && Number.isFinite(audio.duration)) {
    navigator.mediaSession.setPositionState({ duration: audio.duration, position: audio.currentTime, playbackRate: audio.playbackRate });
  }
});

audio.addEventListener('loadedmetadata', () => {
  timeTotal.textContent = formatTime(audio.duration);
  fsTimeTotal.textContent = formatTime(audio.duration);
});

audio.addEventListener('play', () => {
  isPlaying = true;
  updatePlayButtonUI();
  document.querySelector('.fullscreen-artwork-card')?.classList.add('playing');
});

audio.addEventListener('pause', () => {
  isPlaying = false;
  updatePlayButtonUI();
  document.querySelector('.fullscreen-artwork-card')?.classList.remove('playing');
});

audio.addEventListener('error', () => {
  if (audio.error) {
    showPlaybackError(new Error(audio.error.message || 'The audio file could not be loaded.'));
  }
});

audio.addEventListener('ended', () => {
  if (repeatMode === 'one') {
    audio.currentTime = 0;
    audio.play();
  } else {
    playNext();
  }
});

// Keyboard and OS media controls work even when the player itself has no focus.
document.addEventListener('keydown', (event) => {
  const editable = event.target.matches('input, textarea, [contenteditable="true"]');
  if (editable && event.key !== 'Escape') return;
  if (event.code === 'Space') { event.preventDefault(); togglePlay(); }
  if (event.key === 'ArrowRight' && !editable) { event.preventDefault(); audio.currentTime = Math.min(audio.duration || Infinity, audio.currentTime + 5); }
  if (event.key === 'ArrowLeft' && !editable) { event.preventDefault(); audio.currentTime = Math.max(0, audio.currentTime - 5); }
  if (event.key.toLowerCase() === 'n' && !editable) playNext();
  if (event.key.toLowerCase() === 'p' && !editable) playPrev();
  if (event.key.toLowerCase() === 'q' && !editable) queueBtn.click();
});

if ('mediaSession' in navigator) {
  navigator.mediaSession.setActionHandler('play', togglePlay);
  navigator.mediaSession.setActionHandler('pause', () => audio.pause());
  navigator.mediaSession.setActionHandler('previoustrack', playPrev);
  navigator.mediaSession.setActionHandler('nexttrack', playNext);
  navigator.mediaSession.setActionHandler('seekbackward', () => { audio.currentTime = Math.max(0, audio.currentTime - 10); });
  navigator.mediaSession.setActionHandler('seekforward', () => { audio.currentTime = Math.min(audio.duration || Infinity, audio.currentTime + 10); });
}

function seekFromProgressBar(event, wrapper) {
  if (!Number.isFinite(audio.duration) || audio.duration <= 0) return;
  const rect = wrapper.getBoundingClientRect();
  const percentage = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
  audio.currentTime = percentage * audio.duration;
  lyricsManualScrollUntil = 0;
  syncLyrics(audio.currentTime);
}

progressBarWrapper.addEventListener('click', (event) => seekFromProgressBar(event, progressBarWrapper));
fsProgressBarWrapper.addEventListener('click', (event) => seekFromProgressBar(event, fsProgressBarWrapper));

volumeBarWrapper.addEventListener('click', (e) => {
  const rect = volumeBarWrapper.getBoundingClientRect();
  const percentage = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  audio.volume = percentage;
  volumeBar.style.width = `${percentage * 100}%`;
  fsVolumeBar.style.width = `${percentage * 100}%`;
});

fsVolumeBarWrapper.addEventListener('click', (e) => {
  const rect = fsVolumeBarWrapper.getBoundingClientRect();
  const percentage = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  audio.volume = percentage;
  volumeBar.style.width = `${percentage * 100}%`;
  fsVolumeBar.style.width = `${percentage * 100}%`;
});

lyricsToggleBtn.addEventListener('click', () => {
  fullscreenOverlay.classList.add('active');
});

btnCloseFs.addEventListener('click', () => {
  fullscreenOverlay.classList.remove('active');
});

sidebarNowPlaying.addEventListener('click', (e) => {
  e.preventDefault();
  if (currentTrackIndex !== -1) {
    fullscreenOverlay.classList.add('active');
  } else {
    alert('Please play a song first.');
  }
});

sidebarTracks.addEventListener('click', (e) => {
  e.preventDefault();
  fullscreenOverlay.classList.remove('active');
  setLibraryView('all');
});

// Native macOS Keyboard Shortcuts listener (Space, Cmd+K, Cmd+1..4)
window.addEventListener('keydown', (e) => {
  const isInputActive = ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName);

  // Cmd+K or Ctrl+K -> Focus Search
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    songSearchInput.focus();
    songSearchInput.select();
    return;
  }

  // Cmd+1..4 -> Switch Library Views
  if ((e.metaKey || e.ctrlKey) && !isInputActive) {
    if (e.key === '1') { e.preventDefault(); setLibraryView('all'); }
    else if (e.key === '2') { e.preventDefault(); setLibraryView('artists'); }
    else if (e.key === '3') { e.preventDefault(); setLibraryView('albums'); }
    else if (e.key === '4') { e.preventDefault(); setLibraryView('liked'); }
    return;
  }

  // Spacebar -> Toggle Play/Pause when not editing inputs
  if (e.code === 'Space' && !isInputActive) {
    e.preventDefault();
    togglePlay();
  }
});

// Restore the last selected native library on every launch (development and bundled).
restoreSavedLibrary();
