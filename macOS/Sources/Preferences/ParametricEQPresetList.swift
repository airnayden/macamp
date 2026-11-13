// ParametricEQPresetList — the saved parametric presets, with save and delete.
//
// A row whose stored filter bank could not be decoded is rendered with an
// "Unreadable" badge and KEEPS its delete button, rather than being hidden. That
// is a deliberate mirror of the store's shape: `ParametricEQPresetStoring.loadAll()`
// never decodes, so one corrupt row cannot empty the list — and a row the listener
// can see but not remove would be worse than one that simply vanished.
import DesignSystem
import SwiftUI
import ViewModels

struct ParametricEQPresetList: View {
    let model: ParametricEQViewModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var isNaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
            header
            if model.presets.isEmpty {
                PreferenceCaption(text: ParametricEQStrings.noPresets)
            } else {
                ForEach(model.presets) { row in
                    presetRow(row)
                }
            }
        }
        .accessibilityIdentifier("eq.parametric.presets")
        .alert(Text(ParametricEQStrings.savePreset), isPresented: $isNaming) {
            TextField(text: $draftName) {
                Text(ParametricEQStrings.savePresetPrompt)
            }
            .accessibilityIdentifier("eq.parametric.presetNameField")
            Button { save() } label: { Text(ParametricEQStrings.saveButton) }
            Button(role: .cancel) { draftName = "" } label: {
                Text(ParametricEQStrings.cancelButton)
            }
        }
    }
}

private extension ParametricEQPresetList {
    var header: some View {
        HStack(spacing: tokens.spacing.small) {
            Text(ParametricEQStrings.presets)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Spacer(minLength: 0)
            Button {
                draftName = model.selectedPresetName ?? model.lastImportedProfileName ?? ""
                isNaming = true
            } label: {
                Text(ParametricEQStrings.savePreset)
            }
            .disabled(model.filters.isEmpty)
            .accessibilityIdentifier("eq.parametric.savePreset")
        }
    }

    func presetRow(_ row: ParametricPresetRow) -> some View {
        HStack(spacing: tokens.spacing.xSmall) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.name)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                subtitle(row)
            }
            Spacer(minLength: tokens.spacing.xSmall)
            Button { model.applyPreset(named: row.name) } label: {
                Text(ParametricEQStrings.applyPreset)
            }
            .disabled(!row.isReadable)
            .accessibilityIdentifier("eq.parametric.preset.apply.\(row.name)")
            Button(role: .destructive) { model.deletePreset(named: row.name) } label: {
                Text(ParametricEQStrings.deletePreset)
            }
            .accessibilityIdentifier("eq.parametric.preset.delete.\(row.name)")
        }
    }

    @ViewBuilder
    func subtitle(_ row: ParametricPresetRow) -> some View {
        if row.isReadable {
            Text(ParametricEQStrings.presetSummary(
                filters: row.filterCount,
                preamp: row.preampDB.formatted(.number.precision(.fractionLength(0 ... 1)))
            ))
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        } else {
            Text(ParametricEQStrings.presetUnreadableBadge)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.warning.resolve(scheme))
                .accessibilityIdentifier("eq.parametric.preset.unreadable.\(row.name)")
        }
    }

    func save() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftName = ""
        guard !name.isEmpty else { return }
        model.savePreset(named: name)
    }
}
