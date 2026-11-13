// The two top-level vocabulary types ``FakePlaylistRepository`` throws and is armed
// with, split out of the main file verbatim.
//
// The split is headroom, not taxonomy. `FakePlaylistRepository.swift` sat at 399 of the
// 400 lines SwiftLint's strict `file_length` allows (`PlayerCore/TestSupport/` is NOT in
// `.swiftlint.yml`'s `excluded` list), so the next method added to a SHIPPED library
// product would have failed the lint gate rather than the build — a trap for whoever
// touched it next.
//
// These two enums were chosen over the fake's nested `Recording`/`ReorderCall`/
// `MembershipCall` types precisely because they are TOP-LEVEL: they move byte for byte,
// with no enclosing `extension` and no re-indentation. The nested types cannot: hoisting
// them into a `public extension FakePlaylistRepository` would make SwiftFormat's
// `extensionAccessControl` rule strip the `public` off each one, which is an edit to the
// moved block and defeats the point of a pure move.
import Foundation

/// Thrown by ``FakePlaylistRepository`` when a test arms a failure.
public enum FakePlaylistRepositoryError: Error, Sendable, Equatable {
    case forcedFailure
    case playlistNotFound(id: Int64)
}

/// Which mutation a test wants to fail, so a caller's rollback path can be driven
/// one step at a time.
///
/// A blanket "fail everything" switch cannot express the case that matters most —
/// *create succeeds, membership fails* — which is exactly the partial-write path a
/// propose-and-apply caller has to compensate for.
public enum FakePlaylistRepositoryOperation: String, Sendable, Equatable, Hashable, CaseIterable {
    case insert
    case create
    case update
    case delete
    case addTrack
    case removeTrack
    case reorder
}
