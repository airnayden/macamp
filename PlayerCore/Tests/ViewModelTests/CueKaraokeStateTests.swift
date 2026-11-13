// Todo 31: karaoke is declared UNAVAILABLE for a cue segment, typed rather than
// silently inert.
//
// `SeparationCacheKey` fingerprints the audio FILE, so every segment of a disc image
// collides on one cache entry and a rendered instrumental could not be attributed to
// the segment that asked for it. The button therefore resolves to
// `.disabled(reason: .cueSegment)`, which the macOS shell already renders through
// `reason.message` without a new case of its own.
import Separation
import Services
import Testing
@testable import ViewModels

@MainActor
struct CueKaraokeStateTests {
    @Test("a cue segment resolves to the typed cue-segment unavailability")
    func cueSegmentIsUnavailable() {
        let state = PlayerViewModel.deriveKaraokeButtonState(
            settingEnabled: true,
            availability: .available,
            coordinatorActive: false,
            preparation: .notPrepared,
            isCueSegment: true
        )

        #expect(state == .disabled(reason: .cueSegment))
    }

    @Test("a cue segment is unavailable even once something has been cached for its file")
    func cueSegmentStaysUnavailableWithACachedInstrumental() {
        let state = PlayerViewModel.deriveKaraokeButtonState(
            settingEnabled: true,
            availability: .available,
            coordinatorActive: false,
            preparation: .cached,
            isCueSegment: true
        )

        #expect(state == .disabled(reason: .cueSegment))
    }

    @Test("a whole-file row is unaffected and still offers an on-demand render")
    func wholeFileRowStaysRenderable() {
        let state = PlayerViewModel.deriveKaraokeButtonState(
            settingEnabled: true,
            availability: .available,
            coordinatorActive: false,
            preparation: .notPrepared,
            isCueSegment: false
        )

        #expect(state == .renderable)
    }

    @Test("an absent model still outranks the cue reason — the build is the more fundamental cause")
    func missingModelOutranksTheCueReason() {
        let state = PlayerViewModel.deriveKaraokeButtonState(
            settingEnabled: true,
            availability: .unavailable(reason: .modelNotBundled),
            coordinatorActive: false,
            preparation: .notPrepared,
            isCueSegment: true
        )

        #expect(state == .disabled(reason: .modelNotBundled))
    }

    @Test("the settings gate still hides the button outright")
    func settingsGateStillHidesTheButton() {
        let state = PlayerViewModel.deriveKaraokeButtonState(
            settingEnabled: false,
            availability: .available,
            coordinatorActive: false,
            preparation: .notPrepared,
            isCueSegment: true
        )

        #expect(state == .hidden)
    }

    @Test("the cue reason carries its own localized explanation")
    func cueReasonHasItsOwnMessage() {
        let cue = String(localized: SeparationUnavailableReason.cueSegment.message)
        let notBundled = String(localized: SeparationUnavailableReason.modelNotBundled.message)

        #expect(!cue.isEmpty)
        #expect(cue != notBundled)
    }
}
