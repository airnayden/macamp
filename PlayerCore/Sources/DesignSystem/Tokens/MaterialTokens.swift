import SwiftUI

/// A translucency level that resolves to a SwiftUI `Material`, with a solid
/// token fallback when reduce-transparency is active (resolved in views via
/// ``ThemePresentationOptions``).
public enum MaterialLevel: Sendable, Equatable, CaseIterable {
    case ultraThin
    case thin
    case regular
    case thick

    public var material: Material {
        switch self {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        }
    }
}

/// Semantic glass/blur levels for overlay surfaces. Components pick a role
/// (`chrome`/`popover`/`hud`) rather than a raw ``MaterialLevel``; each resolves
/// to a SwiftUI `Material`, collapsing to a solid token under reduce-transparency.
public struct MaterialTokens: Sendable, Equatable {
    public var chrome: MaterialLevel
    public var popover: MaterialLevel
    public var hud: MaterialLevel
    public var modalScrimOpacity: Double

    public init(
        chrome: MaterialLevel,
        popover: MaterialLevel,
        hud: MaterialLevel,
        modalScrimOpacity: Double
    ) {
        self.chrome = chrome
        self.popover = popover
        self.hud = hud
        self.modalScrimOpacity = modalScrimOpacity
    }
}

public extension MaterialTokens {
    static let standard = MaterialTokens(
        chrome: .ultraThin,
        popover: .regular,
        hud: .thick,
        modalScrimOpacity: 0.45
    )
}
