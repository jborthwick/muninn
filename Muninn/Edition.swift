import Foundation

/// Which build of Muninn this is.
///
/// - **Muninn** (shipping): podcast player + transcripts. Publisher transcripts and
///   manual on-device transcription stay; the experimental pipeline is switched off.
/// - **Muninn Labs** (`MUNINN_LABS` compilation condition): everything.
///
/// The Fandom wiki insight feature is compile-time only — its sources are excluded
/// from the shipping target in `project.yml`, so call sites use `#if MUNINN_LABS`.
/// Everything below is still compiled into both editions and gated at runtime, so
/// flipping a flag is enough to try a feature in the shipping app.
enum Edition {
    #if MUNINN_LABS
    static let isLabs = true
    #else
    static let isLabs = false
    #endif

    /// Auto-transcribe after download, auto-generate chapters, and their Settings toggles.
    static let autoProcessing = isLabs

    /// Foundation Models chapter boundaries/titles/summaries. When off, "Generate
    /// Chapters" only imports timestamps found in the episode's show notes.
    static let aiChapters = isLabs

    /// "Recap" button in Now Playing (on-device summary of what you've heard so far).
    static let pauseRecap = isLabs

    /// Chapter/recap debug sheets and the crash log viewer.
    static let debugTools = isLabs
}
