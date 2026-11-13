// AppEnvironment+Crossfeed — puts the stored crossfeed choice into the signal path at
// launch.
//
// A sibling-file extension for the reason `OutputRoutingWiring` is one: the
// composition root's designated initializer sits at the SwiftLint body-length ceiling,
// and every feature that grows it makes the next one harder to add.
//
// Adopting is the WHOLE of launch wiring here — there is no change seam to subscribe
// to, because the model persists and programmes in the same write. A launch where the
// stored state is OFF still runs this: the seam's disable path returns early when no
// node is installed, so the call is inert rather than a second code path.
import Foundation

extension AppEnvironment {
    /// Programmes the stage with whatever was stored, without writing anything back.
    func connectCrossfeed() {
        crossfeed.start()
    }
}
