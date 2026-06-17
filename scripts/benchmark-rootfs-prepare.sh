#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILDER="${BUILDX_BUILDER:-primer-builder}"
REGISTRY="${REGISTRY:-127.0.0.1:5001}"
REGISTRY_PORT="${REGISTRY_PORT:-${REGISTRY##*:}}"
PUSH_REGISTRY="${PUSH_REGISTRY:-host.docker.internal:$REGISTRY_PORT}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-primer-registry-$REGISTRY_PORT}"
IMAGE_NAME="${IMAGE_NAME:-container-primer}"
IMAGE_TAR="${IMAGE_TAR:-.local/image.tar}"
VARIANTS="${VARIANTS:-uncompressed gzip-1 gzip-6 gzip-9}"
APPROACHES="${APPROACHES:-primer daemon-load daemon-pull}"
OUTPUT_DIR="${OUTPUT_DIR:-.local/benchmarks/$(date +%Y%m%d-%H%M%S)}"
PLATFORM="${PLATFORM:-linux/arm64}"
ISOLATED_DAEMON="${ISOLATED_DAEMON:-true}"
RESTORE_DAEMON="${RESTORE_DAEMON:-true}"
PRIMER_CONFIGURATION="${PRIMER_CONFIGURATION:-release}"
CONTAINER_SYSTEM_TIMEOUT="${CONTAINER_SYSTEM_TIMEOUT:-300}"
PRIMER_BINARY="./.build/$PRIMER_CONFIGURATION/ContainerPrimer"

mkdir -p "$OUTPUT_DIR"

CSV="$OUTPUT_DIR/results.csv"
printf 'variant,approach,reference,image_tar_bytes,real_seconds,exit_code,log\n' >"$CSV"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Benchmarks rootfs preparation across OCI layer compression variants.

Environment overrides:
  VARIANTS      Space-separated variants: uncompressed gzip-1 gzip-6 gzip-9 zstd-3
  APPROACHES    Space-separated approaches: primer daemon-load daemon-pull
  OUTPUT_DIR    Output directory for logs and results.csv
  REGISTRY      Local registry host:port for daemon-pull (default: 127.0.0.1:5001)
  REGISTRY_PORT Host port mapped to registry container port 5000 (default: parsed from REGISTRY)
  PUSH_REGISTRY Registry host:port used by buildx to push (default: host.docker.internal:
                REGISTRY_PORT)
  ISOLATED_DAEMON
                Use a fresh container --app-root for each daemon timing (default: true)
  RESTORE_DAEMON
                Restore the previously running daemon app-root on exit (default: true)
  PRIMER_CONFIGURATION
                Swift build configuration for ContainerPrimer prepare (default: release)

Examples:
  VARIANTS="uncompressed gzip-1" APPROACHES="primer daemon-load" scripts/benchmark-rootfs-prepare.sh
  APPROACHES="daemon-pull" REGISTRY=127.0.0.1:5001 scripts/benchmark-rootfs-prepare.sh
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ORIGINAL_DAEMON_RUNNING=false
ORIGINAL_DAEMON_APP_ROOT=""
STARTED_ISOLATED_DAEMON=false
if status_output="$(container system status 2>/dev/null)"; then
  ORIGINAL_DAEMON_RUNNING=true
  ORIGINAL_DAEMON_APP_ROOT="$(awk '$1 == "appRoot" { $1=""; sub(/^ +/, ""); print }' <<<"$status_output")"
fi

restore_daemon() {
  if [[ "$STARTED_ISOLATED_DAEMON" != "true" || "$RESTORE_DAEMON" != "true" ]]; then
    return
  fi
  container system stop >/dev/null 2>&1 || true
  if [[ "$ORIGINAL_DAEMON_RUNNING" == "true" ]]; then
    if [[ -n "$ORIGINAL_DAEMON_APP_ROOT" ]]; then
      container system start --app-root "$ORIGINAL_DAEMON_APP_ROOT" --timeout 180 >/dev/null 2>&1 || true
    else
      container system start --timeout 180 >/dev/null 2>&1 || true
    fi
  fi
}
trap restore_daemon EXIT

compression_options() {
  local variant="$1"
  case "$variant" in
    uncompressed)
      printf 'compression=uncompressed,force-compression=true'
      ;;
    gzip-*)
      printf 'compression=gzip,compression-level=%s,force-compression=true' "${variant#gzip-}"
      ;;
    zstd-*)
      printf 'compression=zstd,compression-level=%s,force-compression=true' "${variant#zstd-}"
      ;;
    *)
      echo "unknown variant: $variant" >&2
      exit 2
      ;;
  esac
}

ensure_builder() {
  docker buildx inspect "$BUILDER" >/dev/null 2>&1 || \
    docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
}

ensure_primer_binary() {
  if [[ ! -x "$PRIMER_BINARY" ]]; then
    swift build --configuration "$PRIMER_CONFIGURATION"
    codesign --force --sign - --entitlements ContainerPrimer.entitlements "$PRIMER_BINARY"
  fi
}

ensure_container_system() {
  if ! container system status >/dev/null 2>&1; then
    container system start
  fi
}

start_isolated_container_system() {
  local variant="$1"
  local approach="$2"
  local root="$OUTPUT_DIR/container-${variant}-${approach}"

  local attempt
  for attempt in 1 2; do
    container system stop >/dev/null 2>&1 || true
    rm -rf "$root"
    mkdir -p "$root/app" "$root/log"
    if container system start \
      --app-root "$ROOT_DIR/$root/app" \
      --log-root "$ROOT_DIR/$root/log" \
      --enable-kernel-install \
      --timeout "$CONTAINER_SYSTEM_TIMEOUT"
    then
      STARTED_ISOLATED_DAEMON=true
      return
    fi
    sleep 5
  done
  return 1
}

prepare_container_system_for_timing() {
  local variant="$1"
  local approach="$2"
  if [[ "$ISOLATED_DAEMON" == "true" ]]; then
    start_isolated_container_system "$variant" "$approach"
  else
    ensure_container_system
  fi
}

ensure_registry() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$REGISTRY_CONTAINER"; then
    docker rm -f "$REGISTRY_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$REGISTRY_CONTAINER" -p "$REGISTRY_PORT:5000" registry:2 >/dev/null
  fi
  curl -fsS "http://$REGISTRY/v2/" >/dev/null
}

build_oci_archive() {
  local variant="$1"
  local ref="$2"
  local options
  options="$(compression_options "$variant")"

  mkdir -p "$(dirname "$IMAGE_TAR")"
  rm -f "$IMAGE_TAR"
  ensure_builder
  docker buildx build --builder "$BUILDER" \
    --platform "$PLATFORM" \
    --provenance=false --sbom=false \
    -t "$ref" \
    --output "type=oci,dest=$IMAGE_TAR,$options" image
}

push_to_registry() {
  local variant="$1"
  local ref="$2"
  local push_ref="$PUSH_REGISTRY/${ref#"$REGISTRY/"}"
  local options
  options="$(compression_options "$variant")"

  ensure_registry
  ensure_builder
  docker buildx build --builder "$BUILDER" \
    --platform "$PLATFORM" \
    --provenance=false --sbom=false \
    -t "$push_ref" \
    --output "type=registry,$options,registry.insecure=true" image
}

image_tar_size() {
  if [[ -f "$IMAGE_TAR" ]]; then
    stat -f '%z' "$IMAGE_TAR"
  else
    printf '0'
  fi
}

clean_primer_rootfs() {
  rm -f .local/rootfs.ext4 .local/rootfs.json .local/rootfs-*.ext4 .local/rootfs-*.json
}

clean_container_image() {
  local ref="$1"
  container image rm -f "$ref" >/dev/null 2>&1 || true
}

record_timing() {
  local variant="$1"
  local approach="$2"
  local ref="$3"
  local log="$4"
  local status="$5"
  local real
  real="$(awk '/^real / { print $2 }' "$log" | tail -n 1)"
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$variant" "$approach" "$ref" "$(image_tar_size)" "${real:-}" "$status" "$log" >>"$CSV"
}

run_timed() {
  local variant="$1"
  local approach="$2"
  local ref="$3"
  shift 3
  local log="$OUTPUT_DIR/${variant}-${approach}.log"
  echo "==> $variant / $approach"
  set +e
  /usr/bin/time -p "$@" >"$log" 2>&1
  local status=$?
  set -e
  cat "$log"
  record_timing "$variant" "$approach" "$ref" "$log" "$status"
  if [[ "$status" -ne 0 ]]; then
    echo "failed: $variant / $approach (exit $status)" >&2
    return "$status"
  fi
}

run_primer() {
  local variant="$1"
  local ref="$2"
  clean_primer_rootfs
  ensure_primer_binary
  run_timed "$variant" primer "$ref" "$PRIMER_BINARY" prepare --force
}

run_daemon_load() {
  local variant="$1"
  local ref="$2"
  prepare_container_system_for_timing "$variant" daemon-load
  clean_container_image "$ref"
  run_timed "$variant" daemon-load "$ref" container image load -i "$IMAGE_TAR"
  clean_container_image "$ref"
}

run_daemon_pull() {
  local variant="$1"
  local ref="$2"
  prepare_container_system_for_timing "$variant" daemon-pull
  clean_container_image "$ref"
  push_to_registry "$variant" "$ref"
  run_timed "$variant" daemon-pull "$ref" container image pull --scheme http --platform "$PLATFORM" --progress plain "$ref"
  clean_container_image "$ref"
}

for variant in $VARIANTS; do
  ref="$REGISTRY/$IMAGE_NAME:bench-$variant-$(date +%s)"
  echo "==> building OCI archive for $variant ($ref)"
  build_oci_archive "$variant" "$ref" | tee "$OUTPUT_DIR/${variant}-build-oci.log"

  for approach in $APPROACHES; do
    case "$approach" in
      primer) run_primer "$variant" "$ref" ;;
      daemon-load) run_daemon_load "$variant" "$ref" ;;
      daemon-pull) run_daemon_pull "$variant" "$ref" ;;
      *)
        echo "unknown approach: $approach" >&2
        exit 2
        ;;
    esac
  done
done

echo "Results: $CSV"
cat "$CSV"
