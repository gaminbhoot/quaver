import { invoke } from '@tauri-apps/api/core';
import { open } from '@tauri-apps/plugin-dialog';

// State
let playlist = [];
let currentTrackIndex = -1;
let isPlaying = false;
let isShuffle = false;
let isRepeat = false;
let lyrics = [];
let activeLyricIndex = -1;

const audio = new Audio();
audio.volume = 0.8;

// DOM
const importBtn = document.getElementById('import-folder-btn');
const tracksListBody = document.getElementById('tracks-list-body');

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

// Fullscreen Now Playing
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

// Native macOS Folder Picker via Tauri Dialog Plugin
importBtn.addEventListener('click', async () => {
  try {
    const selected = await open({
      directory: true,
      multiple: false,
      title: 'Select Music Folder (Local or External Drive)'
    });

    if (selected && typeof selected === 'string') {
      scanFolder(selected);
    }
  } catch (err) {
    console.error('Error opening folder dialog:', err);
  }
});

// Invoke Rust Backend to Scan Directory
async function scanFolder(folderPath) {
  tracksListBody.innerHTML = `
    <tr>
      <td colspan="5" style="text-align: center; padding: 4rem 1rem;">
        <div class="empty-icon">⚡</div>
        <h3>Indexing folder with Rust core...</h3>
        <p>Parsing FLAC & ALAC audio metadata high-speed.</p>
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

function renderPlaylist() {
  if (playlist.length === 0) {
    tracksListBody.innerHTML = `
      <tr class="empty-state">
        <td colspan="5" style="text-align: center; padding: 4rem 1rem;">
          <div class="empty-icon">📁</div>
          <h3>No music loaded yet</h3>
          <p>Click "Add Music Folder" to select your FLAC/ALAC library.</p>
        </td>
      </tr>
    `;
    return;
  }

  tracksListBody.innerHTML = '';
  playlist.forEach((track, index) => {
    const row = document.createElement('tr');
    if (index === currentTrackIndex) {
      row.classList.add('playing');
    }

    row.addEventListener('click', () => {
      playTrack(index);
    });

    row.innerHTML = `
      <td class="col-num">${index + 1}</td>
      <td class="col-title">
        <div style="display: flex; align-items: center; gap: 8px;">
          ${track.cover ? `<img src="${track.cover}" style="width: 28px; height: 28px; border-radius: 4px; object-fit: cover;" />` : `<div style="width: 28px; height: 28px; border-radius: 4px; background-color:#27272a;"></div>`}
          <div>${track.title}</div>
        </div>
      </td>
      <td class="col-album">${track.album}</td>
      <td class="col-type"><span style="background-color:#27272a; padding: 2px 6px; border-radius:4px; font-size:11px;">${track.format}</span></td>
      <td class="col-duration">${formatTime(track.duration)}</td>
    `;
    tracksListBody.appendChild(row);
  });
}

// Play track by index
async function playTrack(index) {
  if (index < 0 || index >= playlist.length) return;

  const rows = tracksListBody.querySelectorAll('tr');
  if (currentTrackIndex >= 0 && currentTrackIndex < rows.length) {
    rows[currentTrackIndex].classList.remove('playing');
  }

  currentTrackIndex = index;
  const track = playlist[currentTrackIndex];

  if (currentTrackIndex >= 0 && currentTrackIndex < rows.length) {
    rows[currentTrackIndex].classList.add('playing');
  }

  // Convert local file path to asset URL (or direct path)
  audio.src = `https://asset.localhost/${encodeURIComponent(track.path)}`;
  audio.play().catch(() => {
    // Fallback URL
    audio.src = track.path;
    audio.play().catch(console.error);
  });

  isPlaying = true;
  updatePlayButtonUI();

  // Load lyrics via Rust IPC if lyricPath exists
  if (track.lyricPath) {
    try {
      const lrcText = await invoke('read_lyrics_file', { filePath: track.lyricPath });
      lyrics = parseLRC(lrcText);
    } catch {
      lyrics = generateMockLyrics(track);
    }
  } else {
    lyrics = generateMockLyrics(track);
  }
  activeLyricIndex = -1;
  renderLyrics();

  // Mini Player UI
  miniTitle.textContent = track.title;
  miniArtist.textContent = track.artist;
  miniCover.style.backgroundImage = track.cover ? `url(${track.cover})` : 'none';

  // Fullscreen UI
  fsWindowTitle.textContent = `Quaver - ${track.title} • ${track.artist} 🔊`;
  fsTrackTitle.textContent = track.title;
  fsTrackArtist.textContent = track.artist;
  fsCoverImage.style.backgroundImage = track.cover ? `url(${track.cover})` : 'none';
  fsBg.style.backgroundImage = track.cover ? `url(${track.cover})` : 'none';
  
  document.querySelector('.fullscreen-artwork-card').classList.add('playing');
}

function parseLRC(text) {
  const lines = text.split('\n');
  const result = [];
  const timeReg = /\[(\d{2}):(\d{2})\.(\d{2,3})\]/;

  for (let line of lines) {
    const match = timeReg.exec(line);
    if (match) {
      const minutes = parseInt(match[1]);
      const seconds = parseInt(match[2]);
      const ms = parseInt(match[3]);
      const time = minutes * 60 + seconds + (ms / (match[3].length === 3 ? 1000 : 100));
      const lyricText = line.replace(timeReg, '').trim();
      if (lyricText) {
        result.push({ time, text: lyricText });
      }
    }
  }
  return result.sort((a, b) => a.time - b.time);
}

function generateMockLyrics(track) {
  return [
    { time: 0, text: `🎶 Playing: ${track.title}` },
    { time: 3, text: `Artist: ${track.artist}` },
    { time: 6, text: `Album: ${track.album}` },
    { time: 9, text: `[High-fidelity ${track.format} audio parsed natively with Rust lofty]` },
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
    div.textContent = line.text;

    div.addEventListener('click', () => {
      audio.currentTime = line.time;
      syncLyrics(line.time);
    });

    syncedLyricsList.appendChild(div);
  });
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
      line.classList.remove('active', 'past', 'upcoming');
      if (index === activeIndex) {
        line.classList.add('active');
        const containerHeight = lyricsContainer.clientHeight;
        const lineOffsetTop = line.offsetTop;
        const lineLimit = lineOffsetTop - containerHeight / 2 + line.clientHeight / 2;
        lyricsContainer.scrollTo({
          top: lineLimit,
          behavior: 'smooth'
        });
      } else if (index < activeIndex) {
        line.classList.add('past');
      } else {
        line.classList.add('upcoming');
      }
    });
  }
}

function togglePlay() {
  if (playlist.length === 0) return;
  if (currentTrackIndex === -1) {
    playTrack(0);
    return;
  }

  if (isPlaying) {
    audio.pause();
    isPlaying = false;
    document.querySelector('.fullscreen-artwork-card').classList.remove('playing');
  } else {
    audio.play();
    isPlaying = true;
    document.querySelector('.fullscreen-artwork-card').classList.add('playing');
  }
  updatePlayButtonUI();
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
  let nextIndex = currentTrackIndex + 1;
  if (isShuffle) {
    nextIndex = Math.floor(Math.random() * playlist.length);
  } else if (nextIndex >= playlist.length) {
    nextIndex = 0;
  }
  playTrack(nextIndex);
}

function playPrev() {
  if (playlist.length === 0) return;
  let prevIndex = currentTrackIndex - 1;
  if (prevIndex < 0) {
    prevIndex = playlist.length - 1;
  }
  playTrack(prevIndex);
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

repeatBtn.addEventListener('click', () => {
  isRepeat = !isRepeat;
  repeatBtn.classList.toggle('active', isRepeat);
  fsRepeatBtn.classList.toggle('active', isRepeat);
});
fsRepeatBtn.addEventListener('click', () => {
  isRepeat = !isRepeat;
  repeatBtn.classList.toggle('active', isRepeat);
  fsRepeatBtn.classList.toggle('active', isRepeat);
});

audio.addEventListener('timeupdate', () => {
  const percent = (audio.currentTime / audio.duration) * 100 || 0;
  progressBar.style.width = `${percent}%`;
  fsProgressBar.style.width = `${percent}%`;
  timeElapsed.textContent = formatTime(audio.currentTime);
  fsTimeElapsed.textContent = formatTime(audio.currentTime);
  syncLyrics(audio.currentTime);
});

audio.addEventListener('loadedmetadata', () => {
  timeTotal.textContent = formatTime(audio.duration);
  fsTimeTotal.textContent = formatTime(audio.duration);
});

audio.addEventListener('ended', () => {
  if (isRepeat) {
    audio.currentTime = 0;
    audio.play();
  } else {
    playNext();
  }
});

progressBarWrapper.addEventListener('click', (e) => {
  const rect = progressBarWrapper.getBoundingClientRect();
  const clickX = e.clientX - rect.left;
  audio.currentTime = (clickX / rect.width) * audio.duration;
});

fsProgressBarWrapper.addEventListener('click', (e) => {
  const rect = fsProgressBarWrapper.getBoundingClientRect();
  const clickX = e.clientX - rect.left;
  audio.currentTime = (clickX / rect.width) * audio.duration;
});

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
});

function formatTime(seconds) {
  if (isNaN(seconds)) return '0:00';
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60).toString().padStart(2, '0');
  return `${m}:${s}`;
}
