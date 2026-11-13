// GeneralLanguageSection — the interface-language picker in Preferences ▸ General.
//
// General is where an app-wide presentation setting belongs — it already owns
// Appearance and Accent Color, the other two "how the whole app looks" choices — and
// the Settings window is at its twelve-tab width floor (`PreferenceMetrics
// .windowMinWidth`, raised 900 → 1000 for the Downloads tab), so a thirteenth tab
// would have to widen it again for one picker.
//
// ── THE CHANGE IS NOT LIVE, AND THE PANE SAYS SO ─────────────────────────────
//
// macOS reads `AppleLanguages` at launch, so nothing on screen re-renders when this
// picker changes — see `AppLanguageOverride`. The caption is therefore permanent
// rather than conditional: it is true before the first change as well as after it,
// and a listener reads it while deciding, not only afterwards.
//
// ── WHY THE STORE ARRIVES THROUGH `init`, NOT `@Environment` ─────────────────
//
// The selection is mirrored in `@State` because the stored value is a `UserDefaults`
// key rather than an `@Observable` property: a binding that re-read it through
// `AppLanguageOverride.current` would never invalidate the view, and the picker would
// sit visibly stuck on the previous row.
//
// Mirroring needs a seed, and seeding in `.task` would be wrong twice over — it
// leaves one frame on the wrong row, and the resulting `onChange` is indistinguishable
// from a listener's choice, so it would raise the relaunch offer on its own. Taking
// the store as an `init` parameter lets `_language` be seeded before the first body
// runs, which removes the seed/choice ambiguity entirely rather than guarding it.
//
// TOOLCHAIN NOTE (Xcode 26.5, `-swift-version 6`): do NOT reach for
// `Binding<AppLanguage?>(get:set:)` here. It crashes swift-frontend in IRGen while
// emitting the reabstraction thunk for the setter
// (`AppLanguageOSgScA_pSgIeAghyg_ADIeAghn_TR`) — a compiler abort, not a diagnostic,
// so it presents as a mystifying "Command SwiftCompile failed" with zero `error:`
// lines in the log. `$language` plus `.onChange` compiles, and is simpler anyway.
import DesignSystem
import Foundation
import SwiftUI

/// Chooses the language the interface is drawn in, applied at the next launch.
struct GeneralLanguageSection: View {
    @State private var language: AppLanguage?
    @State private var pendingRelaunch = false
    @State private var relaunchFailed = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _language = State(initialValue: AppLanguageOverride.current(in: defaults))
    }

    var body: some View {
        Section {
            picker
            PreferenceCaption(text: PreferencesStrings.languageCaption)
            if pendingRelaunch {
                relaunchButton
            }
            if relaunchFailed {
                PreferenceCaption(text: PreferencesStrings.languageRelaunchFailed)
                    .accessibilityIdentifier("preferences.general.languageRelaunchFailed")
            }
        }
        .onChange(of: language) { _, chosen in choose(chosen) }
    }

    /// Every row carries an `AppLanguage?` tag, System included — a `Picker` whose
    /// selection type no tag matches writes its own value back and the row goes blank.
    ///
    /// The names are `Text(verbatim:)` because they are not this app's copy to
    /// translate: ``AppLanguage/endonym`` asks Foundation for each language's own
    /// name, so a catalog key would be seven English strings that could only ever
    /// drift from what the OS itself says.
    private var picker: some View {
        Picker(selection: $language) {
            Text(PreferencesStrings.languageSystem).tag(AppLanguage?.none)
            ForEach(AppLanguage.allCases) { language in
                Text(verbatim: language.endonym).tag(AppLanguage?.some(language))
            }
        } label: {
            Text(PreferencesStrings.language)
        }
        .pointingHandCursor()
        .accessibilityIdentifier("preferences.general.languagePicker")
    }

    private var relaunchButton: some View {
        Button(action: relaunch) {
            Text(PreferencesStrings.languageRelaunch)
        }
        .pointingHandCursor()
        .help(PreferencesStrings.languageRelaunchHelp)
        .accessibilityIdentifier("preferences.general.languageRelaunchButton")
    }

    private func choose(_ chosen: AppLanguage?) {
        AppLanguageOverride.apply(chosen, in: defaults)
        relaunchFailed = false
        pendingRelaunch = true
    }

    /// `relaunch()` only terminates once its helper has spawned, so a `false` here
    /// means the app is still running and the listener has to restart it themselves.
    private func relaunch() {
        relaunchFailed = !AppLanguageOverride.relaunch()
    }
}

#Preview("Language") {
    GeneralPreferencesPane()
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
