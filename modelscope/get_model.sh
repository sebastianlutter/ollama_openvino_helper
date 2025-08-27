#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./pack_openvino_ollama.sh <modelscope_model_id> [--alias NAME] [--device DEVICE] [--ctx N]
                            [--venv PATH] [--out-dir DIR] [--force]

Examples:
  ./pack_openvino_ollama.sh zhaohb/Qwen3-8B-int4-sym-ov-npu
  ./pack_openvino_ollama.sh zhaohb/Qwen3-8B-int4-sym-ov-npu --alias qwen3-8b-ov-npu
  ./pack_openvino_ollama.sh zhaohb/Qwen3-8B-int4-sym-ov-npu --device "AUTO:NPU,CPU" --ctx 8192

Options:
  --alias NAME      Optional Ollama model name/alias (default: derived from model id, lowercased)
  --device DEVICE   Infer device string for OpenVINO (default: AUTO:NPU,CPU; use NPU, GPU, CPU, etc.)
  --ctx N           num_ctx parameter in Modelfile (default: 8192)
  --venv PATH       Path to Python venv to use/create (default: .venv)
  --out-dir DIR     Directory to store downloaded files before tarring (default: ov_models)
  --force           Overwrite existing download/tar/Modelfile if present
  -h, --help        Show this help
USAGE
}

# ---- defaults ----
MODEL_ID="${1:-}"
ALIAS=""
DEVICE="AUTO:NPU,CPU"
CTX="8192"
VENV_DIR="venv"
OUT_DIR="ov_models"
FORCE=0

# ---- parse args ----
if [[ $# -eq 0 ]]; then usage; exit 1; fi
shift 1 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias) ALIAS="${2:?}"; shift 2;;
    --device) DEVICE="${2:?}"; shift 2;;
    --ctx) CTX="${2:?}"; shift 2;;
    --venv) VENV_DIR="${2:?}"; shift 2;;
    --out-dir) OUT_DIR="${2:?}"; shift 2;;
    -f|--force) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1"; usage; exit 1;;
  esac
done

# ---- helpers ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }

# ---- sanity checks ----
need_cmd python3
need_cmd tar

# Try to source OpenVINO env if present (harmless if absent)
if [[ -f "/opt/intel/openvino/setupvars.sh" ]]; then
  # shellcheck disable=SC1091
  source /opt/intel/openvino/setupvars.sh || true
fi

# ---- venv setup ----
if [[ -d "$VENV_DIR" && -f "$VENV_DIR/bin/activate" ]]; then
  echo "Using existing venv: $VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
else
  echo "Creating venv at: $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip
fi

# Ensure modelscope is available
if ! command -v modelscope >/dev/null 2>&1; then
  echo "Installing modelscope into venv..."
  pip install "modelscope>=1.9.0"
fi

# ---- derive names/paths ----
BASE_NAME="${MODEL_ID##*/}"                          # last path segment
SAFE_BASE="$(echo "$BASE_NAME" | tr '/:@ ' '____')"  # sanitize
ALIAS="${ALIAS:-$(echo "$SAFE_BASE" | tr '[:upper:]' '[:lower:]')}"
MODEL_DIR="${OUT_DIR}/${SAFE_BASE}"
TAR_NAME="${SAFE_BASE}.tar.gz"
MODELFILE="Modelfile"

mkdir -p "$OUT_DIR"

# ---- download ----
if [[ -d "$MODEL_DIR" ]]; then
  if [[ $FORCE -eq 1 ]]; then
    echo "Removing existing model dir: $MODEL_DIR"
    rm -rf "$MODEL_DIR"
  else
    echo "Model directory already exists: $MODEL_DIR"
    echo "Use --force to re-download."
    exit 1
  fi
fi

echo "Downloading ModelScope model: $MODEL_ID"
modelscope download --model "$MODEL_ID" --local_dir "$MODEL_DIR"

# ---- package ----
if [[ -f "$TAR_NAME" && $FORCE -eq 0 ]]; then
  echo "Tar already exists: $TAR_NAME  (use --force to overwrite)"
  exit 1
fi

echo "Creating tarball: $TAR_NAME"
tar -C "$OUT_DIR" -zcvf "$TAR_NAME" "$SAFE_BASE" >/dev/null

# ---- Modelfile ----
if [[ -f "$MODELFILE" && $FORCE -eq 0 ]]; then
  echo "Modelfile already exists (use --force to overwrite)."
  exit 1
fi

cat > "$MODELFILE" <<EOF
FROM $TAR_NAME
ModelType "OpenVINO"
InferDevice "$DEVICE"

# Common generation parameters — tweak as you like:
PARAMETER num_ctx $CTX
PARAMETER temperature 0.7
PARAMETER top_p 0.95
PARAMETER top_k 50
EOF

# ---- summary ----
echo
echo "✅ Done."
echo "• Downloaded to:     $MODEL_DIR"
echo "• Tarball created:   $TAR_NAME"
echo "• Modelfile written: $MODELFILE"
echo
echo "Next steps (inside your OpenVINO-Ollama container):"
echo "  ollama create $ALIAS -f $MODELFILE"
echo "  ollama run $ALIAS -p 'Hello, OpenVINO!'"

