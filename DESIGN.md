# Design System

## Theme & Mood
The interface is designed as a premium, native macOS app that defaults to a deep monochromatic dark mode (Drenched Black) to let cover art colors and lyrics pop.

## Typography
- **Primary Font**: `Outfit`, Sans-Serif
- **Header Weights**: `600` (Semi-bold), `700` (Bold)
- **Active Lyric weight**: `700` (Bold)
- **Lyrics Scale**:
  - Inactive/Future lines: `26px`, regular weight, `opacity: 0.35`, `filter: blur(1px)`
  - Active line: `32px`, bold, `opacity: 1.0`, `filter: blur(0)`, `text-shadow: 0 0 20px rgba(255,255,255,0.3)`

## Color Palette
```css
:root {
  --bg-window: #09090b;          /* Dark window background */
  --bg-sidebar: #121214;         /* Darker sidebar background */
  --bg-player: #18181b;          /* Control bar background */
  --foreground: #f4f4f5;         /* Crisp white text */
  --muted-foreground: #a1a1aa;   /* Faded gray text */
  --border: #27272a;             /* Subtle borders */
  --active-highlight: #ffffff;   /* Pure white focus */
}
```

## Key Visual Elements

### 1. Circular Record Artwork (Left Column)
- Rotating album cover styled as a vinyl/CD record.
- Inner circular spindle hole overlay (`48px` center cutout).
- Infinite linear rotation animation that plays during track playback.

### 2. Apple Music Synced Lyrics (Right Column)
- Synchronized vertical scrolling based on playback progress.
- Dynamic transition scales (`scale(0.96)` to `scale(1)`) and progressive blur transitions between active, past, and upcoming lines.

### 3. Glassmorphic Background Canvas
- A heavily blurred (`blur(80px)`), low-brightness background layer showing a mesh gradient derived from the active album cover art.
