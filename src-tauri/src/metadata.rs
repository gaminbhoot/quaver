//! Audio metadata extraction using the `lofty` crate.

use std::fs::File;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use lofty::file::AudioFile;
use lofty::file::TaggedFileExt;
use lofty::probe::Probe;
use lofty::tag::Accessor;
use serde::{Deserialize, Serialize};

/// A scanned track stripped of any transient I/O state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Track {
    pub path: String,
    pub file_name: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_secs: Option<f64>,
    pub has_cover_art: bool,
    pub has_lyrics: bool,
}

/// Full metadata for a single file, including cover art as base64.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metadata {
    pub path: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub genre: Option<String>,
    pub year: Option<u16>,
    pub duration_secs: Option<f64>,
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub bits_per_sample: Option<u8>,
    pub codec: Option<String>,
    /// Cover art encoded as `data:image/<mime>;base64,<...>` ready for `<img src>`.
    pub cover_art: Option<String>,
    pub lyrics_path: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum MetadataError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("lofty error: {0}")]
    Lofty(#[from] lofty::error::LoftyError),
}

/// Walk a list of files and extract metadata for each.
pub fn extract_metadata_for_files(paths: &[PathBuf]) -> Result<Vec<Metadata>, MetadataError> {
    let mut out = Vec::with_capacity(paths.len());
    for p in paths {
        match extract_one(p) {
            Ok(m) => out.push(m),
            Err(_e) => {
                // Skip unreadable files but keep going — bad metadata is not fatal.
                continue;
            }
        }
    }
    Ok(out)
}

fn extract_one(path: &Path) -> Result<Metadata, MetadataError> {
    let tagged = Probe::open(path)?.read()?;

    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());

    let (title, artist, album, track_number, disc_number, genre, year) = if let Some(t) = tag {
        (
            t.title().map(|s| s.into_owned()),
            t.artist().map(|s| s.into_owned()),
            t.album().map(|s| s.into_owned()),
            t.track().map(|n| n as u32),
            t.disk().map(|n| n as u32),
            t.genre().map(|s| s.into_owned()),
            // `date()` returns a Timestamp; year() is not on the Accessor trait.
            t.date().map(|ts| ts.year),
        )
    } else {
        (None, None, None, None, None, None, None)
    };

    let props = tagged.properties();
    let duration_secs = props.duration().as_secs_f64();
    let bitrate = props.audio_bitrate();
    let sample_rate = props.sample_rate();
    // `bit_depth` is the canonical method name in lofty 0.24.
    let bits_per_sample = props.bit_depth();
    let codec = Some(format!("{:?}", tagged.file_type()));

    let cover_art = tag
        .and_then(|t| t.pictures().first())
        .map(|pic| {
            let mime = pic.mime_type().map(|m| m.to_string()).unwrap_or_else(|| "image/jpeg".to_string());
            let b64 = base64::engine::general_purpose::STANDARD.encode(pic.data());
            format!("data:{};base64,{}", mime, b64)
        });

    let lyrics_path = find_lyrics_for(path);

    Ok(Metadata {
        path: path.to_string_lossy().to_string(),
        title,
        artist,
        album,
        track_number,
        disc_number,
        genre,
        year,
        duration_secs: Some(duration_secs),
        bitrate,
        sample_rate,
        bits_per_sample,
        codec,
        cover_art,
        lyrics_path: lyrics_path.map(|p| p.to_string_lossy().to_string()),
    })
}

/// Best-effort companion `.lrc` lookup:
/// `song.flac` -> `song.lrc` (same directory).
fn find_lyrics_for(audio_path: &Path) -> Option<PathBuf> {
    let stem = audio_path.file_stem()?;
    let parent = audio_path.parent()?;
    let candidate = parent.join(format!("{}.lrc", stem.to_string_lossy()));
    if candidate.exists() {
        Some(candidate)
    } else {
        None
    }
}

/// Used by `scanner` to surface a lightweight result during the initial scan.
pub fn quick_metadata(path: &Path) -> Option<Track> {
    let file_name = path.file_name()?.to_string_lossy().to_string();
    let title = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string());
    let mut track = Track {
        path: path.to_string_lossy().to_string(),
        file_name,
        title,
        artist: None,
        album: None,
        duration_secs: None,
        has_cover_art: false,
        has_lyrics: find_lyrics_for(path).is_some(),
    };
    if let Ok(tagged) = Probe::open(path).and_then(|p| p.read()) {
        if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
            track.artist = tag.artist().map(|s| s.into_owned());
            track.album = tag.album().map(|s| s.into_owned());
            track.has_cover_art = !tag.pictures().is_empty();
        }
        track.duration_secs = Some(tagged.properties().duration().as_secs_f64());
    }
    let _ = File::open(path); // touch fs to surface read errors early
    Some(track)
}
