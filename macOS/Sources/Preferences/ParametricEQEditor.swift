// ParametricEQEditor — the parametric filter-bank editor.
//
// ONE view shared by both surfaces: the Equalizer preferences pane and the EQ
// panel's Parametric mode. Sharing it is the point — two editors over one view
// model would be two places for a band row to drift.
//
// It holds NO equalizer logic. Every control writes through `ParametricEQViewModel`
// (add/remove/replace a band, set the trim, import a profile), which is the one
// thing that talks to the engine. The pre-amp in particular is pushed as part of
// the configuration and routed to the gain composer by the engine seam, so nothing
// here ever writes a gain.
//
// The graphic equalizer is not referenced anywhere in this file.
import AudioEngine
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import ViewModels

/// The Graphic | Parametric selector.
///
/// The identifier is injected rather than hardcoded because both surfaces show
/// this control: the EQ panel keeps the canonical `eq.modeToggle`, while the
/// Equalizer preferences pane takes a distinct one so an XCUITest query can never
/// match two live pickers when both windows happen to be open.
struct ParametricEQModePicker: View {
    let model: ParametricEQViewModel
    var identifier: String = "eq.modeToggle"

    var body: some View {
        Picker(selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
            Text(ParametricEQStrings.modeGraphic).tag(EqualizerMode.graphic)
            Text(ParametricEQStrings.modeParametric).tag(EqualizerMode.parametric)
        } label: {
            Text(ParametricEQStrings.mode)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(identifier)
    }
}

struct ParametricEQEditor: View {
    let model: ParametricEQViewModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.small) {
            actionRow
            bandList
            preampRow
            if model.hasApproximatedShelfSlope {
                PreferenceCaption(text: ParametricEQStrings.shelfApproximated)
            }
            ParametricEQPresetList(model: model)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(Text(ParametricEQStrings.importFailedTitle), isPresented: failureBinding) {
            Button { model.clearFailure() } label: {
                Text(ParametricEQStrings.dismissButton)
            }
        } message: {
            if let failure = model.lastFailure {
                Text(ParametricEQFailureCopy.message(for: failure))
            }
        }
        .task { model.loadPresets() }
    }
}

// MARK: - Rows

private extension ParametricEQEditor {
    var actionRow: some View {
        HStack(spacing: tokens.spacing.small) {
            Button { isImporting = true } label: {
                Text(ParametricEQStrings.importProfile)
            }
            .accessibilityIdentifier("eq.parametric.import")

            Button { model.addFilter() } label: {
                Text(ParametricEQStrings.addBand)
            }
            .disabled(!model.canAddFilter)
            .accessibilityIdentifier("eq.parametric.addBand")

            Button { model.reset() } label: {
                Text(ParametricEQStrings.reset)
            }
            .disabled(model.filters.isEmpty && model.preampDB == 0)
            .accessibilityIdentifier("eq.parametric.reset")

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    var bandList: some View {
        if model.filters.isEmpty {
            PreferenceCaption(text: ParametricEQStrings.noBands)
        } else {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                columnHeader
                ForEach(Array(model.filters.enumerated()), id: \.offset) { index, filter in
                    ParametricBandRow(index: index, filter: filter, model: model)
                }
            }
            .accessibilityIdentifier("eq.parametric.bands")
            PreferenceCaption(text: ParametricEQStrings.capacityCaption)
        }
    }

    var columnHeader: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            caption(ParametricEQStrings.bandType, width: ParametricBandMetrics.type)
            caption(ParametricEQStrings.frequency, width: ParametricBandMetrics.frequency)
            caption(ParametricEQStrings.gain, width: ParametricBandMetrics.gain)
            caption(ParametricEQStrings.qFactor, width: ParametricBandMetrics.qFactor)
            Spacer(minLength: 0)
        }
    }

    func caption(_ text: LocalizedStringResource, width: CGFloat) -> some View {
        Text(text)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            .frame(width: width, alignment: .leading)
    }

    var preampRow: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Text(ParametricEQStrings.preamp)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            TextField(value: preampBinding, format: .number) {
                Text(ParametricEQStrings.preamp)
            }
            .labelsHidden()
            .frame(width: ParametricBandMetrics.gain)
            .accessibilityIdentifier("eq.parametric.preamp")
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Bindings + actions

private extension ParametricEQEditor {
    var preampBinding: Binding<Double> {
        Binding(get: { model.preampDB }, set: { model.setPreamp($0) })
    }

    var failureBinding: Binding<Bool> {
        Binding(
            get: { model.lastFailure != nil },
            set: { if !$0 { model.clearFailure() } }
        )
    }

    /// A file chosen through the picker arrives security-scoped, so the read has to
    /// be bracketed — the same shape `ProfileEditorAvatarSection` uses.
    func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        model.importProfile(from: url)
    }
}

// MARK: - One band

enum ParametricBandMetrics {
    static let type: CGFloat = 108
    static let frequency: CGFloat = 78
    static let gain: CGFloat = 64
    static let qFactor: CGFloat = 56
}

private struct ParametricBandRow: View {
    let index: Int
    let filter: ParametricFilter
    let model: ParametricEQViewModel

    @Environment(\.designTokens) private var tokens

    var body: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Picker(selection: field(\.type)) {
                Text(ParametricEQStrings.typePeaking).tag(ParametricFilterType.peaking)
                Text(ParametricEQStrings.typeLowShelf).tag(ParametricFilterType.lowShelf)
                Text(ParametricEQStrings.typeHighShelf).tag(ParametricFilterType.highShelf)
            } label: {
                Text(ParametricEQStrings.bandType)
            }
            .labelsHidden()
            .frame(width: ParametricBandMetrics.type)
            .accessibilityIdentifier("eq.parametric.band.\(index).type")

            numberField(
                field(\.frequency),
                width: ParametricBandMetrics.frequency,
                label: ParametricEQStrings.frequency
            )
            .accessibilityIdentifier("eq.parametric.band.\(index).frequency")
            numberField(field(\.gainDB), width: ParametricBandMetrics.gain, label: ParametricEQStrings.gain)
                .accessibilityIdentifier("eq.parametric.band.\(index).gain")
            numberField(field(\.qFactor), width: ParametricBandMetrics.qFactor, label: ParametricEQStrings.qFactor)
                .accessibilityIdentifier("eq.parametric.band.\(index).q")

            Button { model.removeFilter(at: index) } label: {
                Label {
                    Text(ParametricEQStrings.removeBand)
                } icon: {
                    Image(systemName: "trash")
                }
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .help(Text(ParametricEQStrings.removeBand))
            .accessibilityIdentifier("eq.parametric.band.\(index).remove")

            Spacer(minLength: 0)
        }
    }

    private func numberField(
        _ value: Binding<Double>,
        width: CGFloat,
        label: LocalizedStringResource
    ) -> some View {
        TextField(value: value, format: .number) {
            Text(label)
        }
        .labelsHidden()
        .frame(width: width)
    }

    /// Writes go through ``ParametricEQViewModel/setFilter(_:at:)`` rather than
    /// mutating an element in place, so every edit takes the one commit path that
    /// validates and pushes.
    private func field<Value>(
        _ keyPath: WritableKeyPath<ParametricFilter, Value>
    ) -> Binding<Value> {
        Binding(
            get: { filter[keyPath: keyPath] },
            set: { newValue in
                var edited = filter
                edited[keyPath: keyPath] = newValue
                model.setFilter(edited, at: index)
            }
        )
    }
}
