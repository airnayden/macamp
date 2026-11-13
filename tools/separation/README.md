# Mel-Band Roformer → Core ML conversion (`tools/separation/`)

Build-time tooling that converts the **Kim Mel-Band Roformer** vocal-removal model to
an Apple **Core ML MLProgram** (`MelBandRoformer.mlpackage`, fp16, macOS 15+ — the
fused SDPA attention op the export relies on does not exist earlier; on macOS 14 the
model fails to load and karaoke resolves `.unavailable`). The app
uses this model — offline, pre-rendered — for **Karaoke mode** (vocal removal).

> **This directory is developer/release tooling only.** MacAMP ships **zero Python**.
> Nothing here is an app runtime dependency. The converted model and any weights are
> **never committed to git** — they are produced here and bundled at build time.

---

## What it produces

Running the converter writes two files into the output directory
(`macOS/Resources/SeparationModel/` by default):

| File | Committed? | Purpose |
|---|---|---|
| `MelBandRoformer.mlpackage` | ❌ never (git-ignored `*.mlpackage`) | The NN body. Xcode compiles it to `MelBandRoformer.mlmodelc` at build time and bundles it via the **optional** Tuist resource glob in `macOS/Project.swift` (`Resources/SeparationModel/*`). Absent ⇒ the app still builds and the karaoke feature resolves to `.unavailable`. |
| `model-manifest.json` | ❌ never (lives under git-ignored `macOS/Resources/SeparationModel/`) | STFT parameters + provenance, read by the Swift `CoreMLSeparator` at load time (todo 6). Its schema is captured by the committed fixture `SeparationTests/Fixtures/model-manifest.sample.json`. |

Both are git-ignored (see repo-root `.gitignore`: `*.mlpackage` and
`macOS/Resources/SeparationModel/`).

### `model-manifest.json` schema (9 keys)

```json
{
  "modelVersion": "kj-melband-roformer-vocals@25f44ffb55ee",
  "sha256": "<sha-256 of the SOURCE .ckpt>",
  "sampleRate": 44100,
  "channels": 2,
  "nFFT": 2048,
  "hopLength": 441,
  "windowLength": 2048,
  "segmentSamples": 352800,
  "overlap": 0.5
}
```

* Every STFT value is **read from the checkpoint's own config**, never guessed
  (`sample_rate`, `stft_n_fft`, `stft_hop_length`, `stft_win_length`,
  `inference.chunk_size`, `inference.num_overlap`).
* `overlap` is the overlap-add **fraction** derived from the config's
  `num_overlap: 2` → `1 - 1/2 = 0.5`.
* `sha256` is the SHA-256 of the **source checkpoint** (`.ckpt`), recorded for
  cache-key versioning (a model bump auto-invalidates the instrumental cache). It is
  **not** compared against the compiled bundle.
* A committed, hand-authored copy of this schema (with the Kim config's real STFT
  values) lives at `SeparationTests/Fixtures/model-manifest.sample.json` so Swift
  unit tests (todos 6/9) never need the real artifact. **Its `sha256` is a
  placeholder** (the well-known SHA-256 of the string `"hello world"`); replace it
  with the real hash only if a test ever needs the true value.

---

## How to run

Requires macOS with Python 3.10+ and the pinned toolchain (torch + coremltools +
huggingface_hub). This needs a dev machine — it is **not** part of CI.

```sh
# 1. Install the build-time toolchain (a venv is recommended).
python3 -m venv .venv-separation && source .venv-separation/bin/activate
python3 -m pip install -r tools/separation/requirements.txt

# 2. Convert. With no --checkpoint/--config the script downloads the pinned Kim
#    checkpoint (~900 MB from Hugging Face) and the pinned config from GitHub,
#    then writes the artifacts into macOS/Resources/SeparationModel/.
python3 tools/separation/convert_melband_roformer.py --verify
```

`--verify` runs an 8-second synthetic-clip parity check (PyTorch vs Core ML) and
**fails (non-zero exit)** if the max absolute difference, relative to the reference
output's peak magnitude, is ≥ `5e-2` (calibrated 2026-07-16: the real-arithmetic
export mirror is exact in fp32 — 9.3e-10 vs the model's complex-path forward — and
fp16 accumulation through the transformer measures ~2.6e-2 relative).

### Common options

```sh
# Use local files instead of downloading:
python3 tools/separation/convert_melband_roformer.py \
    --checkpoint /path/to/MelBandRoformer.ckpt \
    --config     /path/to/config_vocals_mel_band_roformer.yaml \
    --output-dir macOS/Resources/SeparationModel \
    --verify

# Fully offline (no network); requires --checkpoint and --config:
python3 tools/separation/convert_melband_roformer.py --no-download \
    --checkpoint ./MelBandRoformer.ckpt --config ./config.yaml --verify
```

### Expected output path

```
macOS/Resources/SeparationModel/
├── MelBandRoformer.mlpackage   (git-ignored)
└── model-manifest.json         (git-ignored)
```

At **build time**, Xcode compiles `MelBandRoformer.mlpackage` →
`MelBandRoformer.mlmodelc` and copies both it and `model-manifest.json` into the app
bundle's `Contents/Resources/`. The Swift side (`CoreMLSeparator`, todo 6) discovers
them via `Bundle.main.url(forResource:withExtension:)`. If the directory is empty
(the normal state for CI and fresh clones), the build still succeeds and karaoke is
`.unavailable`.

---

## Release / distribution flow

* **Direct / Sparkle builds (and CI release):** the release pipeline (`scripts/release.sh`
  stage [1] / CI `release` job) runs the converter **before** `tuist generate` so the
  artifact lands in `macOS/Resources/SeparationModel/` and gets bundled. The resource glob
  is evaluated at generate time — a model fetched afterwards never enters the build graph.
  Stage [7] asserts `MelBandRoformer.mlmodelc` is present in the shipped bundle. See
  [`docs-site/content/docs/distribution.mdx`](../../docs-site/content/docs/distribution.mdx).
* **Dev clones (default):** build **without** the model — everything compiles green and
  karaoke resolves `.unavailable`. Run the converter manually when you need to test
  karaoke locally. The empty-glob build is the CI-equivalent proof.

---

## Build-time bundling (Tuist resource glob)

The macOS app target (`macampMac` in [`macOS/Project.swift`](../../macOS/Project.swift))
carries an **optional** resource glob:

```swift
private let separationModelResources: ResourceFileElements = [
    "Resources/SeparationModel/*",
]
```

* **Absent / empty directory ⇒ green build.** `Resources/SeparationModel/` is
  git-ignored and absent in CI + fresh clones. Tuist tolerates the zero-match glob
  (no warning, no error), so `tuist generate` + `xcodebuild … macampMac` succeed
  with **no** model present — the CI-equivalent proof. Karaoke then resolves to
  `.unavailable`. No `FileManager` guard in the manifest is needed.
* **Model present ⇒ compiled + bundled.** When the converter has populated the
  directory, `tuist generate` wires `MelBandRoformer.mlpackage` into the target as a
  single opaque resource, and Xcode's CoreML model compiler emits
  `Contents/Resources/MelBandRoformer.mlmodelc` into the built `.app`, copying
  `model-manifest.json` alongside it. That compiled `.mlmodelc` (not the raw
  `.mlpackage`) is exactly what `CoreMLSeparator` discovers at runtime.
* **The pattern is `*`, not `**`, on purpose.** A recursive `**` descends *into* the
  `.mlpackage` wrapper and tries to add its inner `Data/com.apple.CoreML/model.mlmodel`
  as a loose build file, which fails `tuist generate` whenever a model is present.
  The non-recursive `*` keeps the `.mlpackage` opaque. Do not "simplify" it back to `**`.

---

## How the conversion works (and the two non-obvious constraints)

1. **STFT / iSTFT are excluded from the Core ML graph.** Core ML has no complex-tensor
   I/O (`apple/coremltools#2130`). The exported model therefore takes the **mixture
   spectrogram** (real/imag as a trailing size-2 axis) and returns the **vocal
   spectrogram** (real/imag). Forward/inverse STFT run in **vDSP on the Swift side**
   (PlayerCore `Separation`, todos 5/6); the complex mask-multiply inside the model is
   expanded to explicit real arithmetic.

2. **Attention is made traceable, not "decomposed".** The Roformer has **no**
   `nn.MultiheadAttention` — attention is hand-rolled. The converter forces the custom
   `Attend` modules onto the direct `F.scaled_dot_product_attention` path (which
   coremltools lowers natively) instead of a flash-attention context manager that does
   not trace.

Conversion call: `torch.jit.trace(..., check_trace=False)` →
`coremltools.convert(convert_to="mlprogram", compute_precision=FLOAT16,
minimum_deployment_target=macOS14)`.

### Provenance (pinned)

| Thing | Source |
|---|---|
| Checkpoint | Hugging Face `KimberleyJSN/melbandroformer` → `MelBandRoformer.ckpt` |
| Config (STFT params) | `KimberleyJensen/Mel-Band-Roformer-Vocal-Model` @ `25f44ffb55ee3c301281bba21b2d6d311cb69ae2`, `configs/config_vocals_mel_band_roformer.yaml` |
| Model class | `lucidrains/BS-RoFormer` @ `84f2b25297424e93f721d5fb9d42291c6d934284` (pinned in `requirements.txt`) |
| Conversion pattern | `ajayarora1235/CoreML-Music-Source-Separation` (MIT) |

> ⚠️ Do **not** substitute ZFTurbo's generic `config_vocals_mel_band_roformer.yaml` —
> it describes a **different** checkpoint (`hop_length=512`, `chunk_size=131584`,
> `num_overlap=4`). The converter sanity-checks the config and refuses to proceed on a
> mismatch.

---

## Troubleshooting

* **`load_state_dict` reports missing parameters** → the installed `bs-roformer`
  version drifted from the checkpoint. Reinstall exactly from `requirements.txt` (it
  pins `bs-roformer` to a git commit).
* **Parity check fails** → the model-body wrapper must be reconciled against the
  installed `bs-roformer` `MelBandRoformer.forward`. This conversion is **human-gated**:
  validate `--verify` on a real dev machine before shipping the artifact.
* **License note:** the Kim checkpoint's license provenance is unverified; attribution
  and the channel policy are recorded in the ADR (plan todo 2) and
  [`docs-site/content/docs/acknowledgments.mdx`](../../docs-site/content/docs/acknowledgments.mdx).
