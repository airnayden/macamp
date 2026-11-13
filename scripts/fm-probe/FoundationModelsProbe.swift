// FoundationModelsProbe — CI canary for the resolved macOS SDK.
//
// WHY THIS EXISTS
// ---------------
// `#if canImport(FoundationModels)` is *SDK*-scoped, not deployment-target-scoped.
// On a CI image whose Xcode predates the macOS 26 SDK the guard evaluates FALSE and
// the entire Foundation-Models orchestration layer compiles OUT — silently, with a
// green build. This file makes that failure LOUD: `#error` is a hard compile error,
// so the `fm-compile-check` CI job turns red instead of passing vacuously.
//
// This is a compile-time probe only. Nothing here is ever executed, linked into a
// shipping binary, or referenced by `Package.swift` / any Tuist target.
//
// RUN IT LOCALLY
// --------------
//   xcrun --sdk macosx swiftc -typecheck -swift-version 6 \
//       scripts/fm-probe/FoundationModelsProbe.swift
//
// Exit 0 => the resolved SDK ships FoundationModels.
// Exit 1 => it does not; FM code would compile out here.

#if canImport(FoundationModels)
    import FoundationModels

    /// Compile-time proof that the resolved SDK exposes the FoundationModels symbols the
    /// assistant layer depends on.
    ///
    /// `@available(macOS 26, iOS 26, *)` is mandatory on every FoundationModels declaration
    /// (weak-linking requirement) — but availability is NEVER a capability proxy. Runtime
    /// capability is decided solely by `SystemLanguageModel.default.availability`, which is
    /// exactly the symbol touched below.
    @available(macOS 26, iOS 26, *)
    enum FoundationModelsSDKProbe {
        /// Touches the system model singleton the capability gate reads.
        static func capabilityGateSymbol() -> SystemLanguageModel {
            SystemLanguageModel.default
        }

        /// Touches the availability enum the capability gate switches over.
        static func availabilityCase() -> SystemLanguageModel.Availability {
            SystemLanguageModel.default.availability
        }
    }
#else
    #error("FoundationModels absent from the resolved SDK — select an Xcode with the macOS 26 SDK.")
#endif
