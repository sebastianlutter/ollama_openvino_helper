#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./import_ov_model_into_container.sh /path/to/model.tar.gz [--container NAME_OR_ID] [--alias NAME] [--dest DIR] [--run]

Notes:
  - The Modelfile must sit next to the .tar.gz (same directory, named "Modelfile").
  - If --container is omitted, the script tries to auto-detect a running container that looks like Ollama (port 11434 or name/image contains 'ollama').
  - If --alias is omitted, it is derived from the tar filename (lowercased, stripped of ".tar.gz").

Examples:
  ./import_ov_model_into_container.sh ./Qwen3-8B-int4-sym-ov-npu.tar.gz --container kind_kalam --alias qwen3-8b-ov-npu
  ./import_ov_model_into_container.sh ./Qwen3-8B-int4-sym-ov-npu.tar.gz --run
USAGE
}

# --- args ---
if [[ $# -lt 1 ]]; then usage; exit 1; fi

TAR_PATH="$(realpath "$1")"; shift || true
CONTAINER=""
ALIAS=""
DEST="/root/modelpack"
DO_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="${2:?}"; shift 2;;
    --alias) ALIAS="${2:?}"; shift 2;;
    --dest) DEST="${2:?}"; shift 2;;
    --run) DO_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# --- checks ---
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need_cmd docker
[[ -f "$TAR_PATH" ]] || { echo "Tar not found: $TAR_PATH"; exit 1; }

TAR_DIR="$(dirname "$TAR_PATH")"
MODELFILE_PATH="$TAR_DIR/Modelfile"
[[ -f "$MODELFILE_PATH" ]] || { echo "Modelfile not found next to tar: $MODELFILE_PATH"; exit 1; }

# Derive alias if not provided
TAR_BASE="$(basename "$TAR_PATH")"
if [[ -z "$ALIAS" ]]; then
  # strip .tar.gz or .tgz
  NAME="$TAR_BASE"
  NAME="${NAME%.tar.gz}"
  NAME="${NAME%.tgz}"
  # sanitize -> lowercase, spaces/slashes->dashes, keep alnum and dashes/underscores only
  ALIAS="$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's#[ /:@]+#-#g; s#[^a-z0-9._-]+##g')"
fi

# Auto-detect container if not provided
if [[ -z "$CONTAINER" ]]; then
  mapfile -t CANDS < <(docker ps --format '{{.ID}}::{{.Names}}::{{.Image}}::{{.Ports}}' | awk -F'::' '
    tolower($0) ~ /ollama/ || $4 ~ /11434/ { print $1
  }')
  if [[ ${#CANDS[@]} -eq 0 ]]; then
    echo "No suitable running container found. Pass --container NAME_OR_ID."
    docker ps
    exit 1
  elif [[ ${#CANDS[@]} -gt 1 ]]; then
    echo "Multiple possible containers found. Please specify one with --container:"
    docker ps --format '  {{.ID}}  {{.Names}}  {{.Image}}  {{.Ports}}'
    exit 1
  else
    CONTAINER="${CANDS[0]}"
  fi
fi

echo "Using container: $CONTAINER"
echo "Alias (ollama model name): $ALIAS"
echo "Destination in container:  $DEST"

# --- copy files into container ---
docker exec "$CONTAINER" mkdir -p "$DEST/$ALIAS"
docker cp "$TAR_PATH" "$CONTAINER:$DEST/$ALIAS/"
docker cp "$MODELFILE_PATH" "$CONTAINER:$DEST/$ALIAS/"

# --- create model inside container ---
# Use bash -lc so we can 'source' if present; harmless if not.
CREATE_CMD=$(cat <<EOF
set -Eeuo pipefail
if [ -f /opt/intel/openvino/setupvars.sh ]; then source /opt/intel/openvino/setupvars.sh || true; fi
export OLLAMA_HOST="127.0.0.1:11434"
cd "$DEST/$ALIAS"
echo "Running: ollama create $ALIAS -f Modelfile"
ollama create "$ALIAS" -f Modelfile
echo "Model created."
ollama list | grep -E "^(NAME|$ALIAS)" || true
EOF
)
docker exec -i "$CONTAINER" bash -lc "$CREATE_CMD"

# --- optional quick test ---
if [[ $DO_RUN -eq 1 ]]; then
  RUN_CMD=$(cat <<EOF
set -Eeuo pipefail
export OLLAMA_HOST="127.0.0.1:11434"
echo "Quick test prompt..."
ollama run "$ALIAS" -p "Hallo! Antworte kurz mit einem Satz."
EOF
)
  docker exec -it "$CONTAINER" bash -lc "$RUN_CMD"
fi

echo
echo "✅ Done. You can now use the model from your host, e.g.:"
echo "  curl http://localhost:11434/api/generate -d '{\"model\":\"$ALIAS\",\"prompt\":\"Hello\"}'"

