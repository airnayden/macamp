// SeparationStrings — every user-facing string in the Separation module.
//
// Centralized as `LocalizedStringResource` keys with an English `defaultValue`,
// exactly like `DesignSystemStrings`. The module never emits a bare literal — error
// and availability copy reference these constants — so it is localization-clean by
// construction. Until the app String Catalogs sync the keys, the `defaultValue`
// renders. Dotted keys follow the project convention (`separation.<area>.<case>`).
import Foundation

/// Localized copy for ``SeparationError`` and ``SeparationUnavailableReason``.
public enum SeparationStrings {
    // MARK: Unavailable reasons

    public static let unavailableModelNotBundled = LocalizedStringResource(
        "separation.unavailable.modelNotBundled",
        defaultValue: "The karaoke model isn't included in this version.",
        comment: "Shown when the separation model is not bundled (App Store build, iOS, or fresh clone)"
    )
    public static let unavailableModelLoadFailed = LocalizedStringResource(
        "separation.unavailable.modelLoadFailed",
        defaultValue: "The karaoke model couldn't be loaded.",
        comment: "Shown when a bundled separation model exists but fails to load"
    )
    public static let unavailableIncompatibleModel = LocalizedStringResource(
        "separation.unavailable.incompatibleModel",
        defaultValue: "The karaoke model is incompatible with this version.",
        comment: "Shown when the model's manifest version or audio parameters don't match the pipeline"
    )
    public static let unavailableCueSegment = LocalizedStringResource(
        "separation.unavailable.cueSegment",
        defaultValue: "Karaoke isn't available for tracks inside a cue sheet.",
        comment: "Shown when the playing track is one segment of a .cue sheet, which cannot be separated"
    )

    // MARK: Errors

    public static let errorModelUnavailable = LocalizedStringResource(
        "separation.error.modelUnavailable",
        defaultValue: "Karaoke mode isn't available.",
        comment: "Error thrown when separation is attempted without a usable model"
    )
    public static let errorUnsupportedChannelLayout = LocalizedStringResource(
        "separation.error.unsupportedChannelLayout",
        defaultValue: "This track's audio layout isn't supported for karaoke.",
        comment: "Error thrown when the source has more channels than the pipeline can process"
    )
    public static let errorDecodeFailed = LocalizedStringResource(
        "separation.error.decodeFailed",
        defaultValue: "This track couldn't be read for karaoke.",
        comment: "Error thrown when the source audio cannot be decoded"
    )
    public static let errorInferenceFailed = LocalizedStringResource(
        "separation.error.inferenceFailed",
        defaultValue: "Separating the vocals failed.",
        comment: "Error thrown when Core ML inference fails during separation"
    )
    public static let errorEncodeFailed = LocalizedStringResource(
        "separation.error.encodeFailed",
        defaultValue: "Saving the karaoke track failed.",
        comment: "Error thrown when encoding the separated instrumental fails"
    )
    public static let errorDiskFull = LocalizedStringResource(
        "separation.error.diskFull",
        defaultValue: "There isn't enough disk space to create the karaoke track.",
        comment: "Error thrown when the device runs out of disk space during separation"
    )

    public static let errorCacheCapacityExceeded = LocalizedStringResource(
        "separation.error.cacheCapacityExceeded",
        defaultValue: "The karaoke track doesn't fit the cache limit. Increase the limit in Karaoke settings and try again.",
        comment: "The rendered audio cannot fit the configured cache limit without removing pinned audio"
    )

    // MARK: Pre-warm notices

    public static let prewarmDiskFullNotice = LocalizedStringResource(
        "separation.prewarm.diskFull",
        defaultValue: "Karaoke pre-warming paused — the disk is full.",
        comment: "Non-fatal notice shown when background karaoke pre-warming stops because the disk is full"
    )
}
