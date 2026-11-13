#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert the Kim Mel-Band Roformer vocal model to a Core ML MLProgram (.mlpackage).

BUILD-TIME TOOL ONLY. MacAMP ships zero Python; this script runs on a developer /
release machine to produce the `MelBandRoformer.mlpackage` that Xcode compiles to
`MelBandRoformer.mlmodelc` and bundles as an OPTIONAL resource. The raw weights and
the .mlpackage are NEVER committed to git (see repo-root .gitignore).

WHY THE GRAPH EXCLUDES STFT / iSTFT
-----------------------------------
Core ML has no complex-number tensor I/O — a model cannot take or return complex
tensors (apple/coremltools#2130, maintainer TobyRoseman:
"we can not support models which input/output complex numbers ... I don't think
torch.fft.irfft is an operation we'll be able to support any time soon"). So we:

  * feed the Core ML model the MIXTURE spectrogram as a REAL tensor (real/imag
    stacked in a trailing size-2 axis), NOT raw audio, and
  * return the VOCAL spectrogram as a REAL tensor, NOT audio.

Forward STFT and inverse STFT therefore live OUTSIDE the graph, in vDSP on the Swift
side (PlayerCore Separation module, plan todos 5/6). The complex mask-multiply that
happens inside the model is expanded to explicit real arithmetic
((a+bi)(c+di) = (ac-bd) + i(ad+bc)) so the exported graph contains no complex ops.
Reference (MIT): ajayarora1235/CoreML-Music-Source-Separation
`models/bs_roformer/bs_roformer_apple_fp16.py` L1019-1041.

ATTENTION ("decompose nn.MultiheadAttention")
---------------------------------------------
The plan says "decompose nn.MultiheadAttention before tracing (reference repo
pattern)". The Roformer family does NOT use `nn.MultiheadAttention` at all — attention
is hand-rolled (manual Q/K/V linear + a custom `Attend` module). The real
Core ML-traceability requirement is to make `Attend` call
`torch.nn.functional.scaled_dot_product_attention` DIRECTLY (coremltools lowers SDPA
natively) instead of routing through flash-attention context managers that do not
trace, and to keep Q/K/V dtypes identical before the SDPA call. `ensure_traceable_
attention()` below enforces exactly that (reference: ajayarora .../attend.py L82-103).

STFT PARAMETERS — SOURCED, NOT GUESSED
--------------------------------------
Every STFT parameter written to the manifest is READ from the checkpoint's own YAML
config (KimberleyJensen/Mel-Band-Roformer-Vocal-Model @ commit
25f44ffb55ee3c301281bba21b2d6d311cb69ae2, configs/config_vocals_mel_band_roformer.yaml):

    sample_rate     = 44100    (config: model.sample_rate)
    stft_n_fft      = 2048     (config: model.stft_n_fft)
    stft_hop_length = 441      (config: model.stft_hop_length)
    stft_win_length = 2048     (config: model.stft_win_length)
    chunk_size      = 352800   (config: inference.chunk_size == 8.0 s @ 44100)
    num_overlap     = 2        (config: inference.num_overlap → 50% overlap-add)

`overlap` in our manifest is the overlap-add FRACTION derived from num_overlap:
overlap = 1 - (chunk_size/num_overlap)/chunk_size = 1 - 1/num_overlap = 0.5 for
num_overlap == 2. (Do NOT import ZFTurbo's generic config — it is a DIFFERENT
checkpoint with hop_length=512, chunk_size=131584, num_overlap=4.)

Usage:
    python3 tools/separation/convert_melband_roformer.py --verify
    python3 tools/separation/convert_melband_roformer.py \
        --checkpoint /path/to/MelBandRoformer.ckpt \
        --config     /path/to/config_vocals_mel_band_roformer.yaml \
        --output-dir macOS/Resources/SeparationModel --verify

Exit codes: 0 success; non-zero on any failure (bad checkpoint path, config mismatch,
conversion error, or parity diff >= tolerance) with a clear message on stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# --- Provenance constants (pinned; see module docstring) --------------------------

KIM_REPO = "KimberleyJensen/Mel-Band-Roformer-Vocal-Model"
KIM_CONFIG_COMMIT = "25f44ffb55ee3c301281bba21b2d6d311cb69ae2"
KIM_CONFIG_URL = (
    f"https://raw.githubusercontent.com/{KIM_REPO}/{KIM_CONFIG_COMMIT}"
    "/configs/config_vocals_mel_band_roformer.yaml"
)
HF_CHECKPOINT_REPO = "KimberleyJSN/melbandroformer"
HF_CHECKPOINT_FILE = "MelBandRoformer.ckpt"

# The model CLASS comes from Kim's own vendored copy at the pinned commit — the exact
# architecture the checkpoint was trained with. lucidrains' upstream `bs-roformer`
# package has since drifted (hyper-connections, value-residual, a default
# linear-transformer slot), so its state_dict no longer matches this checkpoint.
KIM_VENDORED_MODEL_FILES = ("__init__.py", "attend.py", "mel_band_roformer.py")
KIM_VENDORED_MODEL_URL = (
    f"https://raw.githubusercontent.com/{KIM_REPO}/{KIM_CONFIG_COMMIT}"
    "/models/mel_band_roformer/{name}"
)

# Stable, provenance-bearing identifier written to the manifest. Ties the artifact to
# the exact config revision so a bump auto-invalidates the instrumental cache (todo 6).
MODEL_VERSION = f"kj-melband-roformer-vocals@{KIM_CONFIG_COMMIT[:12]}"

DEFAULT_OUTPUT_DIR = Path("macOS/Resources/SeparationModel")
MLPACKAGE_NAME = "MelBandRoformer.mlpackage"
MANIFEST_NAME = "model-manifest.json"

# Parity tolerance: fp16 mlprogram vs fp32 PyTorch on an 8 s clip, as max abs diff
# RELATIVE to the reference output's peak magnitude. CALIBRATED 2026-07-16 on the real
# conversion: the traceable mirror is exact in fp32 (9.3e-10 vs the complex-path
# reference), and fp16 accumulation through the 6-layer transformer measures ~2.6e-2
# relative — the original blind 1e-2 ABSOLUTE tolerance predates any real run and was
# scale-ignorant. 5e-2 relative keeps genuine graph bugs (which show up orders of
# magnitude larger) failing loudly.
PARITY_MAX_REL_DIFF = 5e-2
PARITY_CLIP_SECONDS = 8.0


class ConversionError(RuntimeError):
    """Raised for any recoverable, user-facing failure (printed, non-zero exit)."""


# --- Config -----------------------------------------------------------------------


@dataclass(frozen=True)
class ModelConfig:
    """The subset of the checkpoint config this converter needs. All values READ from
    the YAML — never hardcoded/guessed."""

    sample_rate: int
    n_fft: int
    hop_length: int
    win_length: int
    segment_samples: int  # inference.chunk_size
    num_overlap: int  # inference.num_overlap
    channels: int  # 2 when model.stereo is true
    raw_model: dict[str, Any]  # full `model:` block, passed to MelBandRoformer(**...)

    @property
    def overlap_fraction(self) -> float:
        """Overlap-add fraction from num_overlap (num_overlap=2 → 0.5)."""
        if self.num_overlap < 1:
            raise ConversionError(f"invalid num_overlap={self.num_overlap} (must be >= 1)")
        return 1.0 - (1.0 / float(self.num_overlap))


def load_config(config_path: Path | None) -> ModelConfig:
    """Load and parse the checkpoint YAML config. Downloads the pinned Kim config when
    no path is given. Raises ConversionError with a clear message on any problem."""
    import yaml  # local import so --help works without the toolchain installed

    if config_path is not None:
        if not config_path.is_file():
            raise ConversionError(f"config not found: {config_path}")
        text = config_path.read_text(encoding="utf-8")
    else:
        print(f"[config] downloading pinned Kim config:\n         {KIM_CONFIG_URL}")
        try:
            with urllib.request.urlopen(KIM_CONFIG_URL, timeout=60) as resp:  # noqa: S310
                text = resp.read().decode("utf-8")
        except Exception as exc:  # noqa: BLE001
            raise ConversionError(f"failed to download config: {exc}") from exc

    try:
        # The config uses `!!python/tuple` tags → UnsafeLoader is required. The source is
        # a pinned GitHub commit / a developer-provided file, not untrusted input.
        doc = yaml.load(text, Loader=yaml.UnsafeLoader)  # noqa: S506
    except Exception as exc:  # noqa: BLE001
        raise ConversionError(f"failed to parse config YAML: {exc}") from exc

    try:
        model = dict(doc["model"])
        inference = dict(doc["inference"])
        cfg = ModelConfig(
            sample_rate=int(model["sample_rate"]),
            n_fft=int(model["stft_n_fft"]),
            hop_length=int(model["stft_hop_length"]),
            win_length=int(model["stft_win_length"]),
            segment_samples=int(inference["chunk_size"]),
            num_overlap=int(inference["num_overlap"]),
            channels=2 if bool(model.get("stereo", True)) else 1,
            raw_model=model,
        )
    except KeyError as exc:
        raise ConversionError(f"config missing required key: {exc}") from exc

    _sanity_check_config(cfg)
    return cfg


def _sanity_check_config(cfg: ModelConfig) -> None:
    """Fail loudly if the config is not the expected Kim vocal checkpoint (guards
    against accidentally feeding ZFTurbo's generic config, which is a different model)."""
    expected = {
        "sample_rate": (cfg.sample_rate, 44100),
        "n_fft": (cfg.n_fft, 2048),
        "hop_length": (cfg.hop_length, 441),
        "win_length": (cfg.win_length, 2048),
        "segment_samples": (cfg.segment_samples, 352800),
    }
    mismatches = [f"{k}={got} (expected {want})" for k, (got, want) in expected.items() if got != want]
    if mismatches:
        raise ConversionError(
            "config values do not match the known Kim vocal checkpoint: "
            + ", ".join(mismatches)
            + ".\nRefusing to guess — pass the correct --config "
            "(config_vocals_mel_band_roformer.yaml from KimberleyJensen/"
            "Mel-Band-Roformer-Vocal-Model)."
        )
    if abs(cfg.segment_samples / cfg.sample_rate - 8.0) > 1e-6:
        raise ConversionError(
            f"chunk_size {cfg.segment_samples} is not 8.0 s at {cfg.sample_rate} Hz"
        )


# --- Checkpoint -------------------------------------------------------------------


def resolve_checkpoint(checkpoint_path: Path | None, allow_download: bool) -> Path:
    """Return a path to the .ckpt, downloading from Hugging Face when not provided."""
    if checkpoint_path is not None:
        if not checkpoint_path.is_file():
            raise ConversionError(f"checkpoint not found: {checkpoint_path}")
        return checkpoint_path

    if not allow_download:
        raise ConversionError(
            "no --checkpoint given and downloads disabled (--no-download). "
            "Provide the MelBandRoformer.ckpt path."
        )

    print(f"[ckpt] downloading {HF_CHECKPOINT_FILE} from HF {HF_CHECKPOINT_REPO} (~900 MB)…")
    try:
        from huggingface_hub import hf_hub_download

        path = hf_hub_download(repo_id=HF_CHECKPOINT_REPO, filename=HF_CHECKPOINT_FILE)
    except Exception as exc:  # noqa: BLE001
        raise ConversionError(f"failed to download checkpoint: {exc}") from exc
    return Path(path)


def sha256_file(path: Path) -> str:
    """Streaming SHA-256 of the source checkpoint (recorded in the manifest for
    cache-key versioning — NOT compared against the compiled bundle, see todo 6)."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


# --- Model + Core ML wrapper ------------------------------------------------------


def fetch_kim_model_class():
    """Download Kim's vendored model package (pinned commit) and import
    `MelBandRoformer` from it."""
    import importlib
    import tempfile

    package_root = Path(tempfile.gettempdir()) / f"kim-melband-{KIM_CONFIG_COMMIT[:12]}"
    package_dir = package_root / "models" / "mel_band_roformer"
    package_dir.mkdir(parents=True, exist_ok=True)
    (package_root / "models" / "__init__.py").touch()

    for name in KIM_VENDORED_MODEL_FILES:
        destination = package_dir / name
        if destination.is_file() and destination.stat().st_size > 0:
            continue
        url = KIM_VENDORED_MODEL_URL.format(name=name)
        print(f"[model] downloading vendored {name}:\n        {url}")
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:  # noqa: S310
                destination.write_bytes(resp.read())
        except Exception as exc:  # noqa: BLE001
            raise ConversionError(f"failed to download vendored model file {name}: {exc}") from exc

    if str(package_root) not in sys.path:
        sys.path.insert(0, str(package_root))
    module = importlib.import_module("models.mel_band_roformer.mel_band_roformer")
    return module.MelBandRoformer


def build_model(cfg: ModelConfig, checkpoint_path: Path):
    """Instantiate MelBandRoformer(**config.model) and load the checkpoint weights.
    Mirrors KimberleyJensen utils.py::get_model_from_config."""
    import torch

    model_class = fetch_kim_model_class()
    model = model_class(**cfg.raw_model)

    try:
        state = torch.load(str(checkpoint_path), map_location="cpu", weights_only=True)
    except TypeError:  # torch < 2.0 has no weights_only kwarg
        state = torch.load(str(checkpoint_path), map_location="cpu")
    if isinstance(state, dict) and "state_dict" in state:
        state = state["state_dict"]

    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing:
        raise ConversionError(
            f"checkpoint is missing {len(missing)} parameters "
            f"(e.g. {missing[:3]}). Kim's vendored model code no longer matches the "
            f"checkpoint — verify KIM_CONFIG_COMMIT ({KIM_CONFIG_COMMIT[:12]}) still "
            "points at the revision the checkpoint was published with."
        )
    if unexpected:
        print(f"[model] warning: {len(unexpected)} unexpected keys ignored (e.g. {unexpected[:3]})")

    model.eval()
    ensure_traceable_attention(model)
    return model


def ensure_traceable_attention(model) -> None:
    """The "decompose MultiheadAttention" step. There is no nn.MultiheadAttention in
    the Roformer; instead we route every `Attend` through a DIRECT
    `F.scaled_dot_product_attention` call (no `sdp_kernel` context manager, which does
    not trace). coremltools lowers that to the FUSED Core ML SDPA op (macOS 15+),
    which never materialises the (frames × frames) attention matrices — the manual
    einsum path peaks at ~5 GB of activations for the 60-band × 8-head × 801-frame
    time attention; fused SDPA cuts that to a fraction. Scale is numerically
    identical: both paths use 1/sqrt(head_dim).

    Reference: ajayarora1235/CoreML-Music-Source-Separation .../attend.py L82-103.
    """
    import torch.nn as nn
    import torch.nn.functional as functional

    def direct_sdpa(self, q, k, v):  # noqa: ANN001 — replaces Attend.flash_attn
        return functional.scaled_dot_product_attention(
            q, k, v, dropout_p=self.dropout if self.training else 0.0
        )

    patched = 0
    patched_classes: set[type] = set()
    for module in model.modules():
        if module.__class__.__name__ == "Attend" and hasattr(module, "flash"):
            if module.__class__ not in patched_classes:
                module.__class__.flash_attn = direct_sdpa
                patched_classes.add(module.__class__)
            module.flash = True
            patched += 1
        if isinstance(module, nn.MultiheadAttention):  # defensive — none expected here
            raise ConversionError(
                "unexpected nn.MultiheadAttention in the model; manual Q/K/V "
                "decomposition would be required before tracing."
            )
    print(f"[model] attention made traceable (fused SDPA): patched {patched} Attend module(s)")


def _make_reference_wrapper(model, cfg: ModelConfig):
    """The EAGER-ONLY parity reference: spectrogram-in → vocal-spectrogram-out through
    the model's own, authoritative forward (complex ops included).

    It monkey-patches `torch.stft`/`torch.istft` FOR THE CALL ONLY:
      * torch.stft(audio, …) is replaced by a no-op that returns the wrapper's
        precomputed REAL spectrogram input as a complex tensor.
      * torch.istft(spec, …) is replaced by an identity that captures the masked
        spectrogram as a real tensor.

    Complex ops (`view_as_complex`, complex multiply) have NO Core ML lowering, so this
    wrapper CANNOT be traced/converted — `_make_coreml_wrapper` below re-expresses the
    same computation in real arithmetic for the exported graph, and the --verify parity
    gate proves the two agree.
    """
    import torch
    import torch.nn as nn

    real_stft = torch.stft
    real_istft = torch.istft

    class _SpectrogramIO(nn.Module):
        def __init__(self, inner, config: ModelConfig):
            super().__init__()
            self.inner = inner
            self.config = config

        def forward(self, mix_spec: "torch.Tensor") -> "torch.Tensor":
            # mix_spec: (batch, channels, freq, frames, 2) real/imag — the mixture STFT
            # computed OUTSIDE the graph (vDSP on the Swift side).
            captured: dict[str, torch.Tensor] = {}

            def fake_stft(_audio, *_a, **_k):
                # Ignore the (dummy) audio; inject our real spectrogram input as complex,
                # with batch and channels PACKED — the model packs audio '* t' before
                # torch.stft, so it expects (batch*channels, freq, frames) back.
                packed = mix_spec.reshape(-1, *mix_spec.shape[2:])
                return torch.view_as_complex(packed.contiguous())

            def fake_istft(spec, *_a, **_k):
                # Short-circuit iSTFT: capture the masked spectrogram, unpacked from the
                # model's (batch*stems*channels, freq, frames) back to the wrapper's
                # symmetric (batch, channels, freq, frames, 2) output shape (stems == 1).
                captured["vocal_spec"] = torch.view_as_real(spec.contiguous()).reshape(mix_spec.shape)
                # Return a dummy waveform of the expected shape so the inner forward's
                # trailing rearrange does not crash; we discard it.
                length = _k.get("length") or (spec.shape[-1] * self.config.hop_length)
                return spec.new_zeros(spec.shape[:-2] + (length,), dtype=torch.float32)

            dummy_audio = torch.zeros(
                mix_spec.shape[0], self.config.channels, self.config.segment_samples,
                dtype=torch.float32,
            )
            torch.stft = fake_stft  # type: ignore[assignment]
            torch.istft = fake_istft  # type: ignore[assignment]
            try:
                self.inner(dummy_audio)
            finally:
                torch.stft = real_stft  # type: ignore[assignment]
                torch.istft = real_istft  # type: ignore[assignment]
            return captured["vocal_spec"]

    return _SpectrogramIO(model, cfg).eval()


def _make_coreml_wrapper(model, cfg: ModelConfig):
    """The TRACEABLE export wrapper: mirrors Kim's `MelBandRoformer.forward` between
    STFT and iSTFT, with every complex-tensor op re-expressed in real arithmetic
    (trailing size-2 real/imag axis) so the whole graph lowers to Core ML.

    Reuses the model's own modules (`band_split`, `layers`, `mask_estimators`) and
    buffers (`freq_indices`, `num_bands_per_freq`) — only the glue between them is
    re-derived. `_make_reference_wrapper` + the --verify parity gate prove this mirror
    is numerically faithful to the model's own complex-path forward.
    """
    import torch
    import torch.nn as nn
    from einops import pack, rearrange, unpack

    class _TraceableSpectrogramIO(nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, mix_spec: "torch.Tensor") -> "torch.Tensor":
            # mix_spec: (batch, channels, freq, frames, 2) real/imag — the mixture STFT
            # computed OUTSIDE the graph (vDSP on the Swift side).
            model = self.inner
            batch = mix_spec.shape[0]

            # Kim forward: 'b s f t c -> b (f s) t c' (stereo merged INTO frequency).
            stft_repr = rearrange(mix_spec, "b s f t c -> b (f s) t c")

            # Kim forward: x = stft_repr[batch_arange, freq_indices] — a per-band
            # frequency gather, batch-independent, so index_select is equivalent.
            x = torch.index_select(stft_repr, 1, model.freq_indices)

            x = rearrange(x, "b f t c -> b t (f c)")
            x = model.band_split(x)

            for time_transformer, freq_transformer in model.layers:
                x = rearrange(x, "b t f d -> b f t d")
                x, ps = pack([x], "* t d")
                x = time_transformer(x)
                (x,) = unpack(x, ps, "* t d")
                x = rearrange(x, "b f t d -> b t f d")
                x, ps = pack([x], "* f d")
                x = freq_transformer(x)
                (x,) = unpack(x, ps, "* f d")

            num_stems = len(model.mask_estimators)
            masks = torch.stack([fn(x) for fn in model.mask_estimators], dim=1)
            masks = rearrange(masks, "b n t (f c) -> b n f t c", c=2)

            # Kim forward's complex section, real-expanded. Overlapping per-band mask
            # estimates are scatter-summed back onto the (f s) axis, averaged by how
            # many bands cover each frequency, then complex-multiplied with the mixture:
            #   (a + bi)(c + di) = (ac − bd) + (ad + bc)i
            mixture = rearrange(stft_repr, "b f t c -> b 1 f t c")
            frames = mixture.shape[-2]
            scatter_indices = (
                model.freq_indices.view(1, 1, -1, 1, 1)
                .expand(batch, num_stems, -1, frames, 2)
            )
            masks_summed = torch.zeros_like(mixture.expand(-1, num_stems, -1, -1, -1)).scatter_add(
                2, scatter_indices, masks
            )
            denom = model.num_bands_per_freq.repeat_interleave(model.audio_channels)
            masks_averaged = masks_summed / denom.view(1, 1, -1, 1, 1).clamp(min=1e-8)

            mix_real, mix_imag = mixture[..., 0], mixture[..., 1]
            mask_real, mask_imag = masks_averaged[..., 0], masks_averaged[..., 1]
            vocal = torch.stack(
                [
                    mix_real * mask_real - mix_imag * mask_imag,
                    mix_real * mask_imag + mix_imag * mask_real,
                ],
                dim=-1,
            )

            vocal = vocal[:, 0]
            return rearrange(vocal, "b (f s) t c -> b s f t c", s=model.audio_channels)

    return _TraceableSpectrogramIO(model).eval()


def _stft_complex(audio, cfg: ModelConfig):
    """Reference forward STFT (used only to build inputs + PyTorch parity baseline)."""
    import torch

    window = torch.hann_window(cfg.win_length)
    return torch.stft(
        audio, n_fft=cfg.n_fft, hop_length=cfg.hop_length, win_length=cfg.win_length,
        window=window, return_complex=True, center=True,
    )


# --- Conversion -------------------------------------------------------------------


def _rank1_einsum_rewritten():
    """Trace-scoped shim: rewrites rotary_embedding_torch's `'..., f -> ... f'` outer-
    product einsum as `t.unsqueeze(-1) * freqs`. coremltools' einsum lowering cannot
    handle a rank-1 operand with an ellipsis; the broadcast multiply is identical math
    and lowers cleanly. Patches the MODULE-bound name (`from torch import einsum`), so
    patching `torch.einsum` alone would not reach these call sites."""
    from contextlib import contextmanager

    import rotary_embedding_torch.rotary_embedding_torch as rotary_module

    real_einsum = rotary_module.einsum

    def shimmed_einsum(equation, *operands):
        if equation.replace(" ", "") == "...,f->...f":
            t, freqs = operands
            return t.unsqueeze(-1) * freqs
        return real_einsum(equation, *operands)

    @contextmanager
    def scope():
        rotary_module.einsum = shimmed_einsum
        try:
            yield
        finally:
            rotary_module.einsum = real_einsum

    return scope()


def convert_to_coreml(wrapper, cfg: ModelConfig, output_dir: Path):
    """Trace and convert the wrapper to a fp16 MLProgram .mlpackage for macOS 14+."""
    import coremltools as ct
    import numpy as np
    import torch

    frames = cfg.segment_samples // cfg.hop_length + 1
    freq_bins = cfg.n_fft // 2 + 1  # 1025
    example = torch.randn(1, cfg.channels, freq_bins, frames, 2, dtype=torch.float32)

    print("[convert] tracing (torch.jit.trace, check_trace=False)…")
    with torch.no_grad(), _rank1_einsum_rewritten():
        traced = torch.jit.trace(wrapper, example, check_trace=False)

    print("[convert] coremltools → mlprogram, fp16, minimum_deployment_target=macOS15…")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mixture_spectrogram", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="vocal_spectrogram", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        # macOS 15 is REQUIRED for the fused SDPA op; a macOS 14 target would make
        # coremltools decompose attention back into matmul+softmax (multi-GB
        # activations). On macOS 14 the model fails to load and karaoke resolves
        # `.unavailable` gracefully — the app itself still supports macOS 14.
        minimum_deployment_target=ct.target.macOS15,
        compute_units=ct.ComputeUnit.ALL,
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    package_path = output_dir / MLPACKAGE_NAME
    mlmodel.save(str(package_path))
    print(f"[convert] wrote {package_path}")
    return package_path


def emit_manifest(cfg: ModelConfig, checkpoint_sha: str, output_dir: Path) -> Path:
    """Write model-manifest.json (all 9 keys) alongside the .mlpackage. Values are read
    from the checkpoint config; sha256 is the source-checkpoint hash."""
    manifest = {
        "modelVersion": MODEL_VERSION,
        "sha256": checkpoint_sha,
        "sampleRate": cfg.sample_rate,
        "channels": cfg.channels,
        "nFFT": cfg.n_fft,
        "hopLength": cfg.hop_length,
        "windowLength": cfg.win_length,
        "segmentSamples": cfg.segment_samples,
        "overlap": cfg.overlap_fraction,
    }
    assert len(manifest) == 9, "manifest must contain exactly 9 keys"
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / MANIFEST_NAME
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[manifest] wrote {path}\n{json.dumps(manifest, indent=2, sort_keys=True)}")
    return path


# --- Parity check -----------------------------------------------------------------


def parity_check(wrapper, package_path: Path, cfg: ModelConfig) -> float:
    """Run one 8 s synthetic clip through the eager complex-path reference wrapper and
    Core ML (the real-arithmetic traced graph); return max abs diff. This proves BOTH
    the real-arithmetic re-expression AND the fp16 conversion in one gate. Raises
    ConversionError if the relative diff >= PARITY_MAX_REL_DIFF."""
    import coremltools as ct
    import numpy as np
    import torch

    n = int(PARITY_CLIP_SECONDS * cfg.sample_rate)  # 352800
    t = torch.linspace(0, PARITY_CLIP_SECONDS, n)
    tone = 0.2 * torch.sin(2 * torch.pi * 220.0 * t) + 0.1 * torch.sin(2 * torch.pi * 660.0 * t)
    audio = torch.stack([tone, tone.roll(37)]).unsqueeze(0)  # (1, 2, n) slightly decorrelated

    # Mixture spectrogram (real/imag) computed outside the graph, per channel.
    specs = [torch.view_as_real(_stft_complex(audio[0, ch], cfg)) for ch in range(cfg.channels)]
    mix_spec = torch.stack(specs, dim=0).unsqueeze(0)  # (1, ch, freq, frames, 2)

    with torch.no_grad():
        pt_out = wrapper(mix_spec).cpu().numpy().astype(np.float32)

    mlmodel = ct.models.MLModel(str(package_path))
    ml_out = mlmodel.predict({"mixture_spectrogram": mix_spec.numpy().astype(np.float32)})
    ml_arr = np.asarray(ml_out["vocal_spectrogram"], dtype=np.float32)

    max_abs_diff = float(np.abs(pt_out - ml_arr).max())
    reference_peak = float(np.abs(pt_out).max())
    rel_diff = max_abs_diff / max(reference_peak, 1e-12)
    print(f"[parity] max abs diff (PyTorch vs Core ML) = {max_abs_diff:.6e} "
          f"(reference peak {reference_peak:.4f} → relative {rel_diff:.6e}, "
          f"tolerance {PARITY_MAX_REL_DIFF:.0e})")
    if rel_diff >= PARITY_MAX_REL_DIFF:
        raise ConversionError(
            f"parity check FAILED: relative max abs diff {rel_diff:.6e} >= {PARITY_MAX_REL_DIFF:.0e}"
        )
    print("[parity] PASS")
    return rel_diff


# --- CLI --------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert the Kim Mel-Band Roformer vocal model to a Core ML .mlpackage.",
    )
    parser.add_argument("--checkpoint", type=Path, default=None,
                        help="Path to MelBandRoformer.ckpt (downloaded from HF if omitted).")
    parser.add_argument("--config", type=Path, default=None,
                        help="Path to config_vocals_mel_band_roformer.yaml (pinned Kim config if omitted).")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR,
                        help=f"Output directory (default: {DEFAULT_OUTPUT_DIR}).")
    parser.add_argument("--no-download", action="store_true",
                        help="Never hit the network; require local --checkpoint/--config.")
    parser.add_argument("--verify", action="store_true",
                        help="Run the 8 s PyTorch-vs-Core ML parity check after conversion.")
    return parser.parse_args(argv)


def run(args: argparse.Namespace) -> int:
    cfg = load_config(args.config)
    checkpoint_path = resolve_checkpoint(args.checkpoint, allow_download=not args.no_download)

    print("[sha256] hashing source checkpoint…")
    checkpoint_sha = sha256_file(checkpoint_path)
    print(f"[sha256] {checkpoint_sha}")

    model = build_model(cfg, checkpoint_path)
    wrapper = _make_coreml_wrapper(model, cfg)
    package_path = convert_to_coreml(wrapper, cfg, args.output_dir)
    emit_manifest(cfg, checkpoint_sha, args.output_dir)

    if args.verify:
        reference = _make_reference_wrapper(model, cfg)
        parity_check(reference, package_path, cfg)

    print(f"\n✅ Done. Artifacts in {args.output_dir}/ "
          f"({MLPACKAGE_NAME} + {MANIFEST_NAME}). Neither is committed to git.")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return run(args)
    except ConversionError as exc:
        print(f"\n❌ error: {exc}", file=sys.stderr)
        return 1
    except ModuleNotFoundError as exc:
        print(
            f"\n❌ missing dependency: {exc}. Install the build-time toolchain first:\n"
            "   python3 -m pip install -r tools/separation/requirements.txt",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
