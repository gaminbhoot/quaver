# Task: Native macOS FLAC/ALAC Music Player (Quaver)

- [x] Planning & Design Setup
  - [x] Create Product specification (PRODUCT.md)
  - [x] Create Design specification (DESIGN.md)
- [ ] Base Architecture & Project Setup
  - [ ] Set up Tauri v2 Desktop App scaffolding with Vite + HTML/JS/CSS
  - [ ] Configure Rust backend for native file system access (external drive selection & security-scoped bookmarks)
- [ ] Core Features
  - [ ] Native macOS folder directory selector
  - [ ] Local music scanner & tag reader (extract metadata & cover art using Rust/JS)
  - [ ] Clean macOS sidebar & tracks list table layout
  - [ ] Fully-immersive Now Playing layout with vinyl-style artwork and blurred mesh backdrop
  - [ ] Synced Scrolling Lyrics (.lrc parser with Apple Music transitions)
- [ ] UI/UX Polishing
  - [ ] macOS native window vibrancy and blurs
  - [ ] Smooth transitions and rotating artwork animation
- [ ] Verification
  - [ ] Test audio playback of FLAC & ALAC formats from local directory
  - [ ] Verify directory access persistence (auto-reload on relaunch)
