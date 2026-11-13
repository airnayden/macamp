// The DSP `SpectrumProvider` (Task 10) is the production audio-analysis source.
// Re-export DSP so that `import Visualizer` (and `@testable import Visualizer`)
// transitively expose `SpectrumProvider` — the host app and the test target can
// then reference it without an explicit `import DSP`. The portability guard
// special-cases the `@_exported` prefix and only forbids AppKit/UIKit, so this
// is safe in the shared core.
@_exported import DSP

/// Adopts the visualizer's pull-based ``SpectrumSource`` contract for the DSP
/// provider.
///
/// `SpectrumProvider` already vends `latestSpectrum()` (128 bands). The protocol
/// supplies the remaining requirements as defaults: `bandCount` is `128` and
/// `latestWaveform()` returns an empty array (the visualizer synthesises a
/// waveform from the spectrum when none is provided).
extension SpectrumProvider: SpectrumSource {}
