# Quaver 🎵

A lightweight, high-performance, and distraction-free native macOS music player specializing in local **FLAC** and **ALAC** audio file playback with Apple Music-inspired synced scrolling lyrics.

Built with **Tauri (Rust backend)** and **Vite + HTML/CSS/JS (Frontend)**.

---

## Key Features

- 🔊 **Hi-Res Audio Playback:** Native-speed reading and streaming of FLAC, ALAC (M4A), and MP3 audio files.
- 📁 **External Storage Support:** Native directory picker that remembers permissions to quickly load libraries directly from external hard drives.
- 🎤 **Immersive Synced Lyrics:** Beautifully designed fullscreen overlay featuring scrolling synced lyrics (`.lrc` files), with active line highlighting, blur transitions, and a cover-art-based gradient mesh background.
- 💿 **Vinyl Style Visuals:** Left-column now-playing view featuring a rotating record disk style artwork container.
- ⚡ **Lightweight Footprint:** Exceptionally small app bundle size (~15MB) and low memory usage compared to Electron players.

---

## Project Documentation & Plans

To read more about the planning specifications, architecture, and roadmaps, check out the following documents:
- [PRODUCT.md](PRODUCT.md) — strategic goals, target audience, and brand personality.
- [DESIGN.md](DESIGN.md) — visual system rules, typography scale, OKLCH theme guidelines, and typography.
- [implementation_plan.md](implementation_plan.md) — technical architecture layout and verification steps.
- [task.md](task.md) — implementation task checklists.

---

## Getting Started

### Prerequisites
Make sure you have the following installed on your Mac:
1. **Rust & Cargo:** `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
2. **Node.js:** (Recommended via `nvm` or Homebrew)

### Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/gaminbhoot/quaver.git
   cd quaver
   ```
2. Install frontend dependencies:
   ```bash
   npm install
   ```

### Development
Launch the app in development mode (spawns the native macOS window client):
```bash
npm run tauri dev
```

### Building for Production
To bundle the production-ready macOS app (`.app` and `.dmg` formats):
```bash
npm run tauri build
```

---

## License
Licensed under the [Apache-2.0 License](https://www.apache.org/licenses/LICENSE-2.0).
