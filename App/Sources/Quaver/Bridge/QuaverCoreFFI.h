// QuaverCoreFFI.h — C ABI exposed by the Rust staticlib.
// Swift imports this via bridging header. No Tauri. No WebView.

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// JSON-encoded Vec<TrackMetadata>. Caller must free the returned string with quaver_free_string.
// Returns NULL on error (caller treats as empty library).
const char *quaver_scan_directory_json(const char *dir_path_utf8);

// Read file at path. Returns NULL on error. Caller frees.
const char *quaver_read_lyrics_file(const char *file_path_utf8);

// Library folder persistence (app_data_dir / library.json).
const char *quaver_get_saved_music_folder(void); // NULL if none / not a dir; caller frees
int quaver_save_music_folder(const char *folder_path_utf8); // 0 ok, non-zero error

// Fallback decode: Symphonia → PCM → WAV. Returns temp WAV path (caller frees) or NULL.
// Temp file is /tmp/quaver_decoded_*.wav, ephemeral.
const char *quaver_decode_to_temp_wav(const char *input_path_utf8);
int quaver_decode_to_wav(const char *input_path_utf8, const char *output_path_utf8);

// Free a string returned by the above.
void quaver_free_string(char *ptr);

#ifdef __cplusplus
}
#endif
