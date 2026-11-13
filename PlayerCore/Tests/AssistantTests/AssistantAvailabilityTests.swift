// AssistantAvailabilityTests — the capability gate, table-tested off a seam.
//
// Every one of the five outcomes is asserted here, INCLUDING the two that no
// machine in CI can produce: `.osTooOld` (this host runs macOS 26 and no pre-26 SDK
// or simulator is installed) and the three Apple reasons (this host's Apple
// Intelligence state is whatever it is). That is only possible because
// ``AssistantAvailability/resolve(raw:intelligenceEnabled:)`` is pure and
// floor-available — it runs on ``RawModelAvailability``, never on
// `SystemLanguageModel`.
//
// DOCUMENTED LIMITATION: `.osTooOld` is a RUNTIME branch, never a compile artifact.
// Building the iOS 17 floor proves the FoundationModels island COMPILES with a
// deployment target below its availability; it does NOT execute the
// `if #available(...) == false` path, because the simulator runs iOS 26. With no
// pre-26 host or simulator installed, the seam test below is the ONLY coverage that
// branch has. This is accepted and recorded, not a gap to be closed here.
import Foundation
import Services
import Testing

@Suite("AssistantAvailabilityMapping")
struct AssistantAvailabilityMappingTests {
    /// One row of the mapping table.
    struct Scenario {
        var raw: RawModelAvailability?
        var intelligenceEnabled: Bool
        var expected: AssistantAvailability
        var label: String
    }

    static let scenarios: [Scenario] = [
        Scenario(
            raw: .available,
            intelligenceEnabled: true,
            expected: .available,
            label: "model available + toggle on"
        ),
        Scenario(
            raw: .deviceNotEligible,
            intelligenceEnabled: true,
            expected: .unavailable(reason: .deviceNotEligible),
            label: "Apple reason: deviceNotEligible"
        ),
        Scenario(
            raw: .appleIntelligenceNotEnabled,
            intelligenceEnabled: true,
            expected: .unavailable(reason: .appleIntelligenceNotEnabled),
            label: "Apple reason: appleIntelligenceNotEnabled"
        ),
        Scenario(
            raw: .modelNotReady,
            intelligenceEnabled: true,
            expected: .unavailable(reason: .modelNotReady),
            label: "Apple reason: modelNotReady"
        ),
        Scenario(
            raw: nil,
            intelligenceEnabled: true,
            expected: .unavailable(reason: .osTooOld),
            label: "app reason: no reading available (pre-26 runtime)"
        ),
        Scenario(
            raw: .available,
            intelligenceEnabled: false,
            expected: .unavailable(reason: .intelligenceDisabled),
            label: "app reason: user toggle off outranks an available model"
        ),
    ]

    @Test("Every raw state maps to its expected availability", arguments: scenarios)
    func mapsEveryState(_ scenario: Scenario) {
        let resolved = AssistantAvailability.resolve(
            raw: scenario.raw,
            intelligenceEnabled: scenario.intelligenceEnabled
        )
        #expect(resolved == scenario.expected, "\(scenario.label)")
    }

    @Test("The user toggle outranks every system state, including osTooOld")
    func toggleOutranksEverySystemState() {
        var readings: [RawModelAvailability?] = RawModelAvailability.allCases
        readings.append(nil)
        let resolved = readings.map {
            AssistantAvailability.resolve(raw: $0, intelligenceEnabled: false)
        }
        let expected = Array(
            repeating: AssistantAvailability.unavailable(reason: .intelligenceDisabled),
            count: readings.count
        )
        #expect(resolved == expected)
    }

    @Test("isAvailable is true only for the available case")
    func isAvailableOnlyWhenAvailable() {
        #expect(AssistantAvailability.available.isAvailable)
        let unavailable = AssistantUnavailableReason.allCases.map {
            AssistantAvailability.unavailable(reason: $0).isAvailable
        }
        #expect(unavailable == Array(repeating: false, count: AssistantUnavailableReason.allCases.count))
    }

    @Test("Apple contributes exactly three reasons; the app adds exactly three")
    func reasonCountsMatchTheContract() {
        // Guards against a future edit quietly adding a reason on either side:
        // the four raw states are Apple's `.available` plus its three — and only
        // three — `UnavailableReason` cases.
        #expect(RawModelAvailability.allCases.count == 4)
        #expect(AssistantUnavailableReason.allCases.count == 6)
    }
}

@Suite("AssistantAvailabilityMessages")
struct AssistantAvailabilityMessageTests {
    @Test("All six reasons carry a distinct catalog key")
    func everyReasonHasADistinctKey() {
        // Asserted on the resource KEY, not on rendered English: a PlayerCore test
        // bundle ships no String Catalog, so every message would resolve to its
        // `defaultValue` regardless of locale and a text comparison would prove
        // nothing about localizability.
        let keys = AssistantUnavailableReason.allCases.map(\.message.key)
        #expect(keys.count == 6)
        #expect(Set(keys).count == keys.count)
    }

    @Test("Every key uses the assistant.availability. namespace")
    func everyKeyIsNamespaced() {
        let keys = AssistantUnavailableReason.allCases.map(\.message.key)
        let namespaced = keys.filter { $0.hasPrefix("assistant.availability.") }
        #expect(namespaced.count == keys.count, "unexpected keys: \(Set(keys).subtracting(namespaced))")
    }
}

@Suite("AssistantAvailabilityProbe")
struct AssistantAvailabilityProbeTests {
    @Test("The real probe reports the user toggle without consulting the system")
    func probeHonoursTheUserToggle() {
        // Host-independent: whatever this machine's Apple Intelligence state is, a
        // disabled master toggle short-circuits ahead of it. This is the one
        // assertion on the production entry point that holds on every runner.
        #expect(
            AssistantAvailabilityProbe.current(intelligenceEnabled: false)
                == .unavailable(reason: .intelligenceDisabled)
        )
    }

    @Test("While Apple Intelligence is retired, the probe never reports it available")
    func retiredTierIsNeverAvailable() {
        guard AppleIntelligenceRetirement.isRetired else { return }
        #expect(AssistantAvailabilityProbe.current(intelligenceEnabled: true) == .unavailable(reason: .retired))
        #expect(AssistantAvailabilityProbe.current(intelligenceEnabled: false) == .unavailable(reason: .intelligenceDisabled))
    }

    @Test("With the toggle on, the probe never blames the toggle")
    func probeNeverBlamesAnEnabledToggle() {
        let resolved = AssistantAvailabilityProbe.current(intelligenceEnabled: true)
        #expect(resolved != .unavailable(reason: .intelligenceDisabled))
    }

    #if canImport(FoundationModels)
        @Test("The FoundationModels island is compiled in, not silently skipped")
        func islandIsCompiledIn() {
            // The VALUE this asserts is secondary; its purpose is to fail at COMPILE
            // time if `AssistantAvailabilityResolver` stops existing — which is what
            // a silently-skipped `#if canImport(FoundationModels)` island looks like.
            // A `swift build` that "succeeds" while compiling the gate out is the
            // exact failure mode todo 1's CI job exists to catch, and this pins the
            // package half of it. Itself guarded by `canImport`, so an SDK without
            // FoundationModels drops the test instead of failing it.
            guard #available(macOS 26, iOS 26, *) else {
                // Reachable only on a pre-26 runtime, where `.osTooOld` is the answer
                // and the resolver must not be called at all.
                #expect(AssistantAvailabilityProbe.current(intelligenceEnabled: true)
                    == .unavailable(reason: .osTooOld))
                return
            }
            let resolved = AssistantAvailabilityResolver.current(intelligenceEnabled: true)
            if AppleIntelligenceRetirement.isRetired {
                // DEPRECATED tier: the resolver still compiles, but the probe no longer consults it.
                _ = resolved
                #expect(AssistantAvailabilityProbe.current(intelligenceEnabled: true) == .unavailable(reason: .retired))
            } else {
                #expect(resolved == AssistantAvailabilityProbe.current(intelligenceEnabled: true))
            }
        }
    #endif
}
