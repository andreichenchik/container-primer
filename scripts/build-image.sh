#!/usr/bin/env bash
# Builds the container image into an OCI archive, or cleans up build artifacts.
# Auto-selects a working container engine: prefers Podman, falls back to Docker.
#
# Usage: build-image.sh build | clean
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

IMAGE_TAG="${IMAGE_TAG:-container-primer:local}"
IMAGE_TAR="${IMAGE_TAR:-.local/image.tar}"
BUILDX_BUILDER="${BUILDX_BUILDER:-primer-builder}"
CONTAINERFILE="${CONTAINERFILE:-image/Containerfile}"
CONTEXT="${CONTEXT:-image}"
PLATFORM="${PLATFORM:-linux/arm64}"

note() { echo "    $*" >&2; }

# True when the engine is installed and its backend (podman machine / docker
# daemon) actually responds.
engine_ready() {
  command -v "$1" >/dev/null 2>&1 && "$1" info >/dev/null 2>&1
}

# Picks the first ready engine into $ENGINE, preferring podman. Prints why each
# candidate was skipped, and a fix hint if none qualify.
select_engine() {
  ENGINE=""
  for e in podman docker; do
    if ! command -v "$e" >/dev/null 2>&1; then
      note "$e: not installed"
      continue
    fi
    if engine_ready "$e"; then
      ENGINE="$e"
      return 0
    fi
    note "$e: installed but backend not running"
  done

  echo "No working container engine found." >&2
  echo "  Start one and retry:" >&2
  echo "    podman -> podman machine start" >&2
  echo "    docker -> start colima or Docker Desktop" >&2
  return 1
}

build() {
  select_engine
  mkdir -p "$(dirname "$IMAGE_TAR")"
  rm -f "$IMAGE_TAR"

  case "$ENGINE" in
    podman)
      echo "==> Using podman (machine running)"
      podman build --platform "$PLATFORM" -t "$IMAGE_TAG" -f "$CONTAINERFILE" "$CONTEXT"
      podman save --format oci-archive -o "$IMAGE_TAR" "$IMAGE_TAG"
      ;;
    docker)
      echo "==> Using docker (daemon reachable)"
      # The OCI exporter is unsupported on Colima's default docker driver, so
      # bootstrap a docker-container buildx builder (idempotent).
      docker buildx inspect "$BUILDX_BUILDER" >/dev/null 2>&1 || \
        docker buildx create --name "$BUILDX_BUILDER" --driver docker-container
      docker buildx build --builder "$BUILDX_BUILDER" \
        --platform "$PLATFORM" \
        --provenance=false --sbom=false \
        -t "$IMAGE_TAG" -f "$CONTAINERFILE" \
        --output "type=oci,dest=$IMAGE_TAR" "$CONTEXT"
      ;;
  esac
}

# Sweep every engine present so switching engines never orphans the other's
# image or builder. Best-effort: failures never abort.
clean() {
  local cleaned=false
  for e in podman docker; do
    engine_ready "$e" || continue
    cleaned=true
    case "$e" in
      podman)
        podman rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
        ;;
      docker)
        docker rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
        docker buildx prune --all --force --builder "$BUILDX_BUILDER" >/dev/null 2>&1 || true
        docker buildx rm "$BUILDX_BUILDER" >/dev/null 2>&1 || true
        ;;
    esac
  done
  [ "$cleaned" = true ] || note "no running engine to clean; skipping image/builder cleanup"
}

case "${1:-}" in
  build) build ;;
  clean) clean ;;
  *)
    echo "Usage: $(basename "$0") build | clean" >&2
    exit 2
    ;;
esac
