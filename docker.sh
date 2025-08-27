#!/usr/bin/env bash
# Manager for a Docker image/container lifecycle:
# - status: show whether the image exists locally and related info
# - build:  build the image (idempotent; use --force to rebuild)
# - run:    run an interactive shell with the specified image
#
# Defaults are derived from your example commands.
# You can override via environment variables:
#   IMAGE_NAME=ollama_openvino_ubuntu24
#   IMAGE_TAG=v1
#   DOCKERFILE=Dockerfile_genai_ubuntu24
#   CONTEXT_DIR=.
#
# Examples:
#   ./manage.sh status
#   ./manage.sh build
#   ./manage.sh build --force
#   ./manage.sh build --no-cache
#   ./manage.sh run

set -Eeuo pipefail

IMAGE_NAME="${IMAGE_NAME:-ollama_openvino_ubuntu24}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
CONTEXT_DIR="${CONTEXT_DIR:-.}"
VOLUME_NAME="${2:-ollama-models}"

# -------- Utility --------
log()   { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
err()   { printf '[ERROR] %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

on_error() {
  local exit_code=$?
  err "Script failed (exit $exit_code) at line ${BASH_LINENO[0]} running: ${BASH_COMMAND}"
  exit "$exit_code"
}
trap on_error ERR

require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker not found in PATH. Please install Docker."
  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon not reachable. Ensure Docker Desktop/daemon is running and you have permission."
  fi
}

image_ref() { printf '%s:%s' "$IMAGE_NAME" "$IMAGE_TAG"; }

image_exists() {
  docker image inspect "$(image_ref)" >/dev/null 2>&1
}

human_size() {
  # Convert bytes to human-readable if numfmt is available
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$1"
  else
    printf '%s bytes' "$1"
  fi
}

status() {
  require_docker

  log "Docker version:"
  docker --version || true
  echo

  log "Configuration:"
  printf '  Image:      %s\n' "$(image_ref)"
  printf '  Dockerfile: %s\n' "$DOCKERFILE"
  printf '  Context:    %s\n' "$CONTEXT_DIR"
  echo

  if [[ -f "$DOCKERFILE" ]]; then
    log "Dockerfile found: $DOCKERFILE (modified: $(date -r "$DOCKERFILE" +"%Y-%m-%d %H:%M:%S"))"
  else
    warn "Dockerfile not found at path: $DOCKERFILE"
  fi
  echo

  if image_exists; then
    log "Local image present: $(image_ref)"
    # Show details
    local fmt='{{.Id}}|{{.Size}}|{{.Created}}'
    IFS='|' read -r iid isize icreated < <(docker image inspect --format "$fmt" "$(image_ref)")
    printf '  Image ID:   %s\n' "$iid"
    printf '  Size:       %s\n' "$(human_size "$isize")"
    printf '  Created:    %s\n' "$icreated"
  else
    warn "Local image NOT present: $(image_ref)"
  fi
  echo

  log "Containers using image (running):"
  if ! docker ps --filter "ancestor=$(image_ref)" --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' | sed 1q | grep -q .; then
    # Ensure header prints even if none
    printf '  (none)\n'
  else
    docker ps --filter "ancestor=$(image_ref)" --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' || true
  fi

  echo
  log "Containers using image (all states):"
  if ! docker ps -a --filter "ancestor=$(image_ref)" --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' | sed 1q | grep -q .; then
    printf '  (none)\n'
  else
    docker ps -a --filter "ancestor=$(image_ref)" --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' || true
  fi
}

build() {
  require_docker

  local force=0
  local no_cache=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      --no-cache) no_cache=1 ;;
      -h|--help)
        cat <<EOF
Usage: $0 build [--force] [--no-cache]

Builds the Docker image $(image_ref) with:
  docker build -t $(image_ref) -f $DOCKERFILE $CONTEXT_DIR

Options:
  --force     Rebuild even if the image already exists.
  --no-cache  Build without using the cache.
EOF
        return 0
        ;;
      *)
        die "Unknown build option: $1"
        ;;
    esac
    shift
  done

  if image_exists && [[ $force -eq 0 ]]; then
    log "Image already exists: $(image_ref)"
    log "Nothing to do. Use '--force' to rebuild."
    return 0
  fi

  [[ -f "$DOCKERFILE" ]] || die "Dockerfile not found: $DOCKERFILE"

  log "Building image: $(image_ref)"
  log "Dockerfile: $DOCKERFILE"
  log "Context:    $CONTEXT_DIR"

  local args=()
  if [[ $no_cache -eq 1 ]]; then
    args+=(--no-cache)
  fi

  docker build "${args[@]}" -t "$(image_ref)" -f "$DOCKERFILE" "$CONTEXT_DIR"
  log "Build completed: $(image_ref)"
}

run_shell() {
  require_docker

  if ! image_exists; then
    die "Image not found locally: $(image_ref)
Please build it first:  $0 build"
  fi

  log "Starting interactive shell in container from image: $(image_ref)"
  set +e
  # Create the volume if it doesn't exist (idempotent)
  docker volume create "$VOLUME_NAME" >/dev/null
  docker run -it -p11434:11434 --rm -v "$VOLUME_NAME":/root/.ollama \
        --device=/dev/dri:/dev/dri \
        --device=/dev/accel/accel0 \
        -e OLLAMA_INTEL_GPU=1 \
        -e OLLAMA_DEBUG=1 \
        "$(image_ref)"
# for non-root add
#        --group-add="$(stat -c '%g' /dev/dri/render* | head -n1)" \
#        --group-add="$(stat -c '%g' /dev/accel/accel0)" \
#        -u "$(id -u):$(id -g)" \

  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    die "docker run exited with status $rc"
  fi
}

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commands:
  status           Show environment, Dockerfile, image presence, and containers using the image.
  build [opts]     Build the image. Options: --force, --no-cache
  run              Run: docker run -it --rm --entrypoint /bin/bash $(image_ref)
  help             Show this help.

Environment overrides:
  IMAGE_NAME   (default: $IMAGE_NAME)
  IMAGE_TAG    (default: $IMAGE_TAG)
  DOCKERFILE   (default: $DOCKERFILE)
  CONTEXT_DIR  (default: $CONTEXT_DIR)
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    status) status "$@" ;;
    build)  build "$@" ;;
    run)    run_shell "$@" ;;
    help|-h|--help) usage ;;
    *) die "Unknown command: $cmd. Run '$0 help' for usage." ;;
  esac
}

main "$@"
