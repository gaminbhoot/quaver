//! Recursive directory scanner for audio + lyric files.

use std::path::Path;

use walkdir::WalkDir;

use crate::metadata::{quick_metadata, Track};

/// Walk `root` recursively and collect every track with a known audio extension.
pub fn scan_directory_recursive(
    root: &Path,
    extensions: &[String],
) -> Result<Vec<Track>, std::io::Error> {
    if !root.exists() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("directory does not exist: {}", root.display()),
        ));
    }

    let exts: Vec<String> = extensions.iter().map(|e| e.to_lowercase()).collect();
    let mut tracks = Vec::new();

    for entry in WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        let ext = path
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_lowercase());
        let Some(ext) = ext else { continue };
        if !exts.contains(&ext) {
            continue;
        }
        if let Some(track) = quick_metadata(path) {
            tracks.push(track);
        }
    }

    // Stable order: by directory then file name.
    tracks.sort_by(|a, b| {
        let da = parent_dir(&a.path);
        let db = parent_dir(&b.path);
        da.cmp(&db).then(a.file_name.cmp(&b.file_name))
    });

    Ok(tracks)
}

fn parent_dir(path: &str) -> String {
    Path::new(path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default()
}
