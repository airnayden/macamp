import Foundation

/// One third-party component shown on the in-app Acknowledgments screen.
///
/// The names, versions and licenses are factual metadata rendered verbatim; they
/// mirror the curated license map in `scripts/generate-acknowledgments.sh`, which
/// generates the full `docs/Acknowledgments.md`. Keep the two in sync.
public struct Acknowledgment: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String?
    public let license: String
    public let role: String
    public let url: String?

    public init(
        name: String,
        version: String? = nil,
        license: String,
        role: String,
        url: String? = nil
    ) {
        id = name
        self.name = name
        self.version = version
        self.license = license
        self.role = role
        self.url = url
    }
}

/// The curated component lists behind the in-app Acknowledgments screen, split by
/// where each component actually ships so an app only acknowledges what it bundles.
public enum Acknowledgments {
    /// Bundled in every MacAMP build (macOS app, iOS app, widget).
    public static let core: [Acknowledgment] = [
        Acknowledgment(
            name: "SFBAudioEngine",
            version: "0.12.1",
            license: "MIT",
            role: "Audio decoding & playback engine",
            url: "https://github.com/sbooth/SFBAudioEngine"
        ),
        Acknowledgment(name: "FLAC", license: "BSD-3-Clause", role: "Lossless codec", url: "https://xiph.org/flac/"),
        Acknowledgment(
            name: "Ogg Vorbis",
            license: "BSD-3-Clause",
            role: "Lossy codec",
            url: "https://xiph.org/vorbis/"
        ),
        Acknowledgment(name: "Opus", license: "BSD-3-Clause", role: "Lossy codec", url: "https://opus-codec.org"),
        Acknowledgment(
            name: "WavPack",
            license: "BSD-3-Clause",
            role: "Lossless / hybrid codec",
            url: "https://www.wavpack.com"
        ),
        Acknowledgment(
            name: "Monkey's Audio",
            license: "BSD-3-Clause",
            role: "Lossless APE codec",
            url: "https://monkeysaudio.com"
        ),
        Acknowledgment(name: "Musepack", license: "BSD-3-Clause", role: "Lossy codec", url: "https://www.musepack.net"),
        Acknowledgment(name: "mpg123", license: "LGPL-2.1", role: "MP3 decoder", url: "https://www.mpg123.de"),
        Acknowledgment(
            name: "LAME",
            license: "LGPL-2.0-or-later",
            role: "MP3 encoder / decoder",
            url: "https://lame.sourceforge.io"
        ),
        Acknowledgment(
            name: "libsndfile",
            license: "LGPL-2.1",
            role: "WAV / AIFF / CAF I/O",
            url: "https://libsndfile.github.io/libsndfile/"
        ),
        Acknowledgment(
            name: "TagLib",
            license: "LGPL-2.1 / MPL-1.1",
            role: "Audio metadata reader",
            url: "https://taglib.org"
        ),
        Acknowledgment(name: "Speex", license: "BSD-3-Clause", role: "Speech codec", url: "https://www.speex.org"),
        Acknowledgment(
            name: "DUMB",
            license: "BSD-like",
            role: "Tracker / module decoder",
            url: "https://github.com/kode54/dumb"
        ),
        Acknowledgment(
            name: "True Audio (TTA)",
            license: "LGPL-2.1",
            role: "Lossless codec",
            url: "https://tausoft.org"
        ),
        Acknowledgment(
            name: "GRDB.swift",
            version: "7.11.1",
            license: "MIT",
            role: "SQLite application database",
            url: "https://github.com/groue/GRDB.swift"
        ),
        Acknowledgment(
            name: "GeneralUser GS",
            license: "GeneralUser GS License",
            role: "General-MIDI SoundFont by S. Christian Collins",
            url: "https://www.schristiancollins.com/generaluser.php"
        ),
    ]

    /// Bundled in macOS builds only (software updates).
    public static let macOS: [Acknowledgment] = [
        Acknowledgment(
            name: "Sparkle",
            version: "2.9.3",
            license: "MIT",
            role: "Software updates",
            url: "https://sparkle-project.org"
        ),
    ]

    /// Bundled only in the macOS "projectM" build (LGPL visualizer + asset packs).
    public static let projectM: [Acknowledgment] = [
        Acknowledgment(
            name: "projectM",
            version: "4.1.6",
            license: "LGPL-2.1",
            role: "MilkDrop visualizer",
            url: "https://github.com/projectM-visualizer/projectm"
        ),
        Acknowledgment(
            name: "Cream of the Crop",
            license: "Public domain",
            role: "MilkDrop preset pack",
            url: "https://github.com/projectM-visualizer/presets-cream-of-the-crop"
        ),
        Acknowledgment(
            name: "MilkDrop Texture Pack",
            license: "Public domain",
            role: "Visualizer textures",
            url: "https://github.com/projectM-visualizer/presets-milkdrop-texture-pack"
        ),
    ]
}
