// AssistantProviderLabelTests — the caption names the tier that will actually answer.
//
// Pure over `LibraryChatRoute`, so none of it needs a model, a provider, a database
// or a running app — the same property that lets `LibraryChatRoutingTests` assert the
// matrix it feeds.
//
// Assertions are on the resource KEY plus the rendered English, never on a
// hand-copied sentence: the key proves WHICH resource was chosen (a translator may
// reword the default), and the render proves the provider and model survived
// interpolation as verbatim data.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Assistant provider label")
struct AssistantProviderLabelTests {
    private static let english = Locale(identifier: "en")

    private static func caption(
        _ route: LibraryChatRoute?,
        models: [String: String] = [:]
    ) -> LocalizedStringResource? {
        AssistantView.providerCaption(route: route, models: models)
    }

    @Test("the on-device route keeps the shipped Apple Intelligence caption")
    func onDeviceKeepsItsExistingCaption() throws {
        let resource = try #require(Self.caption(.appleIntelligence))
        #expect(resource.key == AssistantPaneStrings.appleIntelligence.key)
        #expect(resource.resolved(in: Self.english) == "Enhanced by Apple Intelligence")
    }

    @Test("a connector route names both the provider and the model it carries")
    func aConnectorNamesItsProviderAndModel() throws {
        let route = LibraryChatRoute.connector(
            id: "claude-subscription",
            displayName: "Claude Subscription",
            model: "claude-sonnet-4-6"
        )
        let resource = try #require(Self.caption(route))
        let rendered = resource.resolved(in: Self.english)

        #expect(resource.key == "app.assistant.poweredBy")
        #expect(rendered.contains("Claude Subscription"))
        #expect(rendered.contains("claude-sonnet-4-6"))
    }

    @Test("a connector with no stored model falls back to the provider-only caption")
    func aConnectorWithNoModelNamesOnlyItsProvider() throws {
        let route = LibraryChatRoute.connector(id: "ollama", displayName: "Ollama", model: "")
        let resource = try #require(Self.caption(route))
        let rendered = resource.resolved(in: Self.english)

        #expect(resource.key == "app.assistant.poweredByProvider")
        #expect(rendered.contains("Ollama"))
        // No dangling separator: the model-less variant is its own sentence, not the
        // two-argument one with a hole where the model would have been.
        #expect(!rendered.contains("—"))
    }

    // MARK: The two inputs, in their documented precedence

    @Test("the route's own model wins over the settings dictionary")
    func theRouteOutranksTheSettingsDictionary() throws {
        let route = LibraryChatRoute.connector(id: "ollama", displayName: "Ollama", model: "llama3.2")
        let resource = try #require(Self.caption(route, models: ["ollama": "stale-model"]))
        let rendered = resource.resolved(in: Self.english)

        #expect(rendered.contains("llama3.2"))
        #expect(!rendered.contains("stale-model"))
    }

    @Test("a route carrying no model reads the settings dictionary")
    func anEmptyRouteModelReadsTheSettingsDictionary() throws {
        let route = LibraryChatRoute.connector(id: "ollama", displayName: "Ollama", model: "")
        let resource = try #require(Self.caption(route, models: ["ollama": "llama3.2"]))

        #expect(resource.key == "app.assistant.poweredBy")
        #expect(resource.resolved(in: Self.english).contains("llama3.2"))
    }

    @Test("a non-ready route shows no caption at all, rather than an error badge")
    func aNonReadyRouteIsHiddenNotBadged() {
        #expect(Self.caption(nil) == nil)
        #expect(Self.caption(nil, models: ["ollama": "llama3.2"]) == nil)
    }
}
