// SpectrogramPredicting — the swappable "neural network" seam of stem separation.
//
// The vocal-estimating model is the one non-deterministic, hard-to-test piece of
// the pipeline, so it hides behind this protocol. Production ships
// `CoreMLSeparator` (an `actor` wrapping a non-Sendable Core ML `MLModel`); tests
// ship `FakeSpectrogramPredictor` (pure Swift, deterministic, no Core ML, no disk).
// A caller chunks a mixture spectrogram into segments and asks the predictor for a
// per-segment VOCAL estimate; the instrumental is then the mixture minus that
// estimate. Segments are STEREO pairs: the Mel-Band Roformer is stereo-native
// (trained on L/R jointly), so a per-channel mono seam would either halve quality
// or double inference cost. `availability` is `async` because the production
// conformer is an actor. This file imports only Foundation and MUST NOT import
// AppKit/UIKit (PlayerCore portability invariant).
import Foundation

/// One stereo window of the mixture spectrogram handed to the model.
///
/// `left`/`right` share the same `frameCount` × `binCount` shape and configuration.
public struct StereoSpectrogramSegment: Sendable {
    public let left: ComplexSpectrogram
    public let right: ComplexSpectrogram

    public init(left: ComplexSpectrogram, right: ComplexSpectrogram) {
        precondition(
            left.frameCount == right.frameCount && left.binCount == right.binCount,
            "stereo segment channels must share one shape"
        )
        self.left = left
        self.right = right
    }
}

/// A model that estimates the vocal content of a single stereo spectrogram segment.
///
/// Conformers are `Sendable` so they can be shared across isolation domains. The
/// segment handed to ``predict(segment:)`` is one stereo window of the mixture
/// spectrogram; the returned ``SegmentOutput`` carries the model's vocal estimate
/// for exactly that window (same shape, both channels).
public protocol SpectrogramPredicting: Sendable {
    /// Whether the model can run right now (loaded + compatible). Callers gate on
    /// this before predicting; an `.unavailable` predictor throws
    /// ``SeparationError/modelUnavailable``.
    var availability: SeparationAvailability { get async }

    /// Estimates the vocal spectrogram for one stereo mixture `segment`.
    ///
    /// - Parameter segment: One stereo window of the mixture spectrogram.
    /// - Returns: The vocal estimate for that window, in the same shape.
    /// - Throws: ``SeparationError/modelUnavailable`` when no model is loaded, or
    ///   ``SeparationError/inferenceFailed`` when the model runs but its output
    ///   cannot be marshalled back.
    func predict(segment: StereoSpectrogramSegment) async throws -> SegmentOutput
}

/// The result of a single-segment prediction: the model's stereo vocal estimate.
public struct SegmentOutput: Sendable {
    /// The estimated vocal spectrogram for the segment's left channel.
    public let vocalLeft: ComplexSpectrogram
    /// The estimated vocal spectrogram for the segment's right channel.
    public let vocalRight: ComplexSpectrogram

    public init(vocalLeft: ComplexSpectrogram, vocalRight: ComplexSpectrogram) {
        self.vocalLeft = vocalLeft
        self.vocalRight = vocalRight
    }
}
