#!/usr/bin/env bash
#
# fetch-and-convert-model.sh — ensure the karaoke separation model is installed.
#
# THE single source of truth for the "model stage". Every caller that needs
# macOS/Resources/SeparationModel/ populated — scripts/build-macamp.sh, the
# release pipeline, a human following docs/Distribution.md — calls THIS script.
# Never re-implement the venv / converter / verify dance anywhere else.
#
# Stages:
#   0. INSPECT — is a valid MelBandRoformer.mlpackage + parseable
#                model-manifest.json already installed? If yes (and no --force),
#                exit 0 immediately ("cached"): no venv, no network, no python.
#   1. VENV    — create .venv-separation (uv, python 3.12) and install
#                tools/separation/requirements.txt when the venv is missing.
#   2. CONVERT — run tools/separation/convert_melband_roformer.py --verify,
#                which downloads the pinned ~900 MB Kim checkpoint on first run
#                (unless --no-download + local --checkpoint/--config are given)
#                and writes both artifacts into macOS/Resources/SeparationModel/.
#   3. VERIFY  — re-assert the installed artifacts: the .mlpackage exists and
#                carries its Manifest.json, and model-manifest.json parses with
#                all 9 keys the Swift CoreMLSeparator reads.
#
# Neither artifact is ever committed to git (see .gitignore). See
# tools/separation/README.md for the conversion internals and provenance.
#
# Usage:
#   tools/separation/fetch-and-convert-model.sh                # ensure (cached-fast)
#   tools/separation/fetch-and-convert-model.sh --force        # reconvert regardless
#   tools/separation/fetch-and-convert-model.sh --dry-run      # print the plan only
#   tools/separation/fetch-and-convert-model.sh --no-download \
#       --checkpoint ./MelBandRoformer.ckpt --config ./config.yaml
#
# Flags:
#   --force              Reconvert even when valid artifacts are already present.
#                        Also bypasses the corrupt-artifact hard stop (exit 3).
#   --dry-run            Print the stage plan and exit. Touches NO network, NO
#                        venv, NO python — it only stats the installed artifacts.
#   --no-download        Pass-through: forbid network fetches in the converter
#                        (then --checkpoint AND --config are required).
#   --checkpoint <path>  Pass-through: local MelBandRoformer.ckpt.
#   --config <path>      Pass-through: local config_vocals_mel_band_roformer.yaml.
#   -h, --help           This text.
#
# Exit codes:
#   0  artifacts installed (converted) or already valid (cached)
#   1  bad arguments / missing repo tooling files
#   2  environment unusable (no .venv-separation and no `uv` to build one)
#   3  installed artifacts are present but INVALID (corrupt manifest / broken
#      .mlpackage) — re-run with --force, or delete the directory, to rebuild
#   4  conversion ran but the expected artifacts are missing or unverifiable
#   *  any other code is convert_melband_roformer.py's own status, propagated
#      unchanged (1 = conversion error, 2 = missing python dependency)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

MODEL_DIR="macOS/Resources/SeparationModel"
MODEL_PACKAGE="${MODEL_DIR}/MelBandRoformer.mlpackage"
MODEL_MANIFEST="${MODEL_DIR}/model-manifest.json"
CONVERTER="tools/separation/convert_melband_roformer.py"
REQUIREMENTS="tools/separation/requirements.txt"
VENV=".venv-separation"
VENV_PYTHON="${VENV}/bin/python"

# The 9 keys the Swift side (Separation/SeparationManifest.swift) decodes.
MANIFEST_KEYS="modelVersion sha256 sampleRate channels nFFT hopLength windowLength segmentSamples overlap"

FORCE=0
DRY_RUN=0
NO_DOWNLOAD=0
CHECKPOINT=""
CONFIG=""

die() { echo "error: $*" >&2; exit 1; }
fail() { local code="$1"; shift; echo "error: $*" >&2; exit "${code}"; }
step() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-download) NO_DOWNLOAD=1; shift ;;
        --checkpoint) [[ $# -ge 2 ]] || die "--checkpoint needs a path"; CHECKPOINT="$2"; shift 2 ;;
        --config) [[ $# -ge 2 ]] || die "--config needs a path"; CONFIG="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
            exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

if [[ "${NO_DOWNLOAD}" -eq 1 ]]; then
    [[ -n "${CHECKPOINT}" ]] || die "--no-download requires --checkpoint <path>"
    [[ -n "${CONFIG}" ]] || die "--config is required with --no-download"
fi
[[ -z "${CHECKPOINT}" || -f "${CHECKPOINT}" ]] || die "--checkpoint not found: ${CHECKPOINT}"
[[ -z "${CONFIG}" || -f "${CONFIG}" ]] || die "--config not found: ${CONFIG}"

# ------------------------------------------------------------ artifact checks

# Echoes a human-readable problem and returns 1 when the installed .mlpackage is
# absent or structurally broken. Returns 0 (silently) when it looks usable.
package_problem() {
    if [[ ! -d "${MODEL_PACKAGE}" ]]; then
        echo "absent"
        return 1
    fi
    if [[ ! -f "${MODEL_PACKAGE}/Manifest.json" ]]; then
        echo "not a valid .mlpackage (no Manifest.json inside)"
        return 1
    fi
    return 0
}

# Echoes a human-readable problem and returns 1 when model-manifest.json is
# absent, unparseable, or missing one of the 9 required keys. Returns 0 (silently)
# when it parses and carries every key.
#
# `plutil -convert` is the parse gate and `plutil -extract` the key gate: both are
# system tools, so the cached fast path never needs python or the venv. (Note:
# `plutil -lint` does NOT accept JSON input — it insists on a property list.)
manifest_problem() {
    if [[ ! -f "${MODEL_MANIFEST}" ]]; then
        echo "absent"
        return 1
    fi
    if ! plutil -convert json -o /dev/null "${MODEL_MANIFEST}" >/dev/null 2>&1; then
        echo "unparseable JSON"
        return 1
    fi
    local key
    for key in ${MANIFEST_KEYS}; do
        if ! plutil -extract "${key}" raw -o - "${MODEL_MANIFEST}" >/dev/null 2>&1; then
            echo "missing required key '${key}'"
            return 1
        fi
    done
    return 0
}

# Sets INSTALL_STATE to ok | absent | corrupt and INSTALL_DETAIL to the reason.
INSTALL_STATE=""
INSTALL_DETAIL=""
inspect_install() {
    local pkg_problem manifest_issue
    pkg_problem="$(package_problem)" || true
    manifest_issue="$(manifest_problem)" || true

    if [[ -z "${pkg_problem}" && -z "${manifest_issue}" ]]; then
        INSTALL_STATE="ok"
        INSTALL_DETAIL="MelBandRoformer.mlpackage + model-manifest.json (9/9 keys)"
    elif [[ "${pkg_problem}" == "absent" && "${manifest_issue}" == "absent" ]]; then
        INSTALL_STATE="absent"
        INSTALL_DETAIL="nothing installed in ${MODEL_DIR}/"
    else
        INSTALL_STATE="corrupt"
        INSTALL_DETAIL=""
        if [[ -n "${pkg_problem}" ]]; then
            INSTALL_DETAIL="MelBandRoformer.mlpackage: ${pkg_problem}"
        fi
        if [[ -n "${manifest_issue}" ]]; then
            if [[ -n "${INSTALL_DETAIL}" ]]; then
                INSTALL_DETAIL="${INSTALL_DETAIL}; "
            fi
            INSTALL_DETAIL="${INSTALL_DETAIL}model-manifest.json: ${manifest_issue}"
        fi
    fi
}

# ---------------------------------------------------------------- 0. INSPECT
step "MODEL: inspecting ${MODEL_DIR}/"
inspect_install
note "state: ${INSTALL_STATE} — ${INSTALL_DETAIL}"

# The converter invocation, assembled once and carried twice: the array is what
# runs (so a path containing spaces survives), the string is what --dry-run
# prints. Both are built together so the printed plan cannot drift from the run.
CONVERTER_ARGS=(--output-dir "${MODEL_DIR}" --verify)
CONVERTER_ARGS_DISPLAY="--output-dir ${MODEL_DIR} --verify"
if [[ "${NO_DOWNLOAD}" -eq 1 ]]; then
    CONVERTER_ARGS+=(--no-download)
    CONVERTER_ARGS_DISPLAY="${CONVERTER_ARGS_DISPLAY} --no-download"
fi
if [[ -n "${CHECKPOINT}" ]]; then
    CONVERTER_ARGS+=(--checkpoint "${CHECKPOINT}")
    CONVERTER_ARGS_DISPLAY="${CONVERTER_ARGS_DISPLAY} --checkpoint ${CHECKPOINT}"
fi
if [[ -n "${CONFIG}" ]]; then
    CONVERTER_ARGS+=(--config "${CONFIG}")
    CONVERTER_ARGS_DISPLAY="${CONVERTER_ARGS_DISPLAY} --config ${CONFIG}"
fi

if [[ "${INSTALL_STATE}" == "corrupt" && "${FORCE}" -eq 0 ]]; then
    echo "error: ${MODEL_DIR}/ holds INVALID artifacts — ${INSTALL_DETAIL}" >&2
    echo "       Re-run with --force to rebuild them, or delete ${MODEL_DIR}/ and retry." >&2
    exit 3
fi

if [[ "${INSTALL_STATE}" == "ok" && "${FORCE}" -eq 0 ]]; then
    step "MODEL: cached — ${MODEL_DIR}/ already valid, nothing to do"
    note "pass --force to reconvert (downloads the ~900 MB checkpoint unless --no-download)"
    exit 0
fi

# ------------------------------------------------------------------- planning
REASON="artifacts absent"
if [[ "${INSTALL_STATE}" == "corrupt" ]]; then
    REASON="artifacts invalid, --force given"
elif [[ "${INSTALL_STATE}" == "ok" ]]; then
    REASON="--force given (valid artifacts will be overwritten)"
fi

VENV_ACTION="reuse ${VENV} (already present)"
if [[ ! -x "${VENV_PYTHON}" ]]; then
    VENV_ACTION="create ${VENV} (uv venv --python 3.12) + uv pip install -r ${REQUIREMENTS}"
fi

DOWNLOAD_NOTE="downloads the pinned ~900 MB Kim checkpoint + config on first run"
if [[ "${NO_DOWNLOAD}" -eq 1 ]]; then
    DOWNLOAD_NOTE="offline (--no-download): uses the given local checkpoint + config"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    UV_PATH="$(command -v uv || true)"
    if [[ -z "${UV_PATH}" ]]; then
        UV_PATH="NOT FOUND (required to create the venv)"
    fi
    step "MODEL: DRY-RUN plan (no network, no venv, no python was touched)"
    note "reason:   ${REASON}"
    note "stage 1:  ${VENV_ACTION}"
    note "stage 2:  ${VENV_PYTHON} ${CONVERTER} ${CONVERTER_ARGS_DISPLAY}"
    note "          ${DOWNLOAD_NOTE}"
    note "stage 3:  verify ${MODEL_PACKAGE} + ${MODEL_MANIFEST} (9/9 manifest keys)"
    note "uv:       ${UV_PATH}"
    echo ""
    echo "DRY-RUN: nothing was downloaded, created, or converted."
    exit 0
fi

[[ -f "${CONVERTER}" ]] || die "converter missing: ${CONVERTER}"

# ------------------------------------------------------------------- 1. VENV
if [[ ! -x "${VENV_PYTHON}" ]]; then
    command -v uv >/dev/null 2>&1 || {
        echo "error: '${VENV}' missing and 'uv' not installed." >&2
        echo "       Install uv (https://docs.astral.sh/uv/) or create the venv per tools/separation/README.md" >&2
        exit 2
    }
    [[ -f "${REQUIREMENTS}" ]] || die "requirements missing: ${REQUIREMENTS}"
    step "MODEL: creating ${VENV} (python 3.12) + installing ${REQUIREMENTS}"
    uv venv --python 3.12 "${VENV}"
    uv pip install --python "${VENV_PYTHON}" -r "${REQUIREMENTS}"
else
    step "MODEL: reusing ${VENV}"
fi

# ---------------------------------------------------------------- 2. CONVERT
step "MODEL: converting — ${REASON}"
note "${DOWNLOAD_NOTE}"
"${VENV_PYTHON}" "${CONVERTER}" "${CONVERTER_ARGS[@]}"

# ----------------------------------------------------------------- 3. VERIFY
step "MODEL: verifying installed artifacts"
inspect_install
case "${INSTALL_STATE}" in
    ok) note "✓ ${INSTALL_DETAIL}" ;;
    absent) fail 4 "conversion finished but ${MODEL_PACKAGE} / ${MODEL_MANIFEST} not found" ;;
    *) fail 4 "conversion finished but the artifacts are invalid — ${INSTALL_DETAIL}" ;;
esac

step "MODEL: done — ${MODEL_DIR}/ ready (never committed to git)"
exit 0
