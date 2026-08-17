#!/usr/bin/env bash
# External-server entrypoint: download a small maintained image set and create
# one transport bundle.  No Volcano source, E2E code, Benchmark code or module
# cache is stored in the bundle.
set -Eeuo pipefail

SCRIPT_VERSION="v4.0.0"
DEFAULT_VOLCANO_REPO="https://github.com/volcano-sh/volcano.git"
DEFAULT_KIND_VERSION="v0.32.0"
DEFAULT_HELM_VERSION="v3.21.4"
DEFAULT_GO_BUILDER="golang:1.26.2"
DEFAULT_RUNTIME_BASE="alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
DEFAULT_E2E_BUSYBOX="busybox:1.36"
DEFAULT_E2E_NGINX="nginx:1.29.3-alpine"
DEFAULT_KWOK_IMAGE="registry.k8s.io/kwok/kwok:v0.7.0"

log() { printf '[vpg4-package] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

usage() {
  cat <<'EOF'
Usage:
  bash volcano-v4-package.sh --k8s-version vX.Y.Z --volcano-ref REF \
    --mode e2e|benchmark|both --output DIR [options]

Required:
  --k8s-version VERSION       Exact Kubernetes version, for example v1.34.8
  --volcano-ref REF           Volcano branch, tag or 40-character commit
  --mode MODE                 e2e, benchmark or both
  --output DIR                Directory receiving the generated bundle

Selection:
  --volcano-repo URL          Default: official Volcano repository
  --kind-version VERSION      Default: v0.32.0
  --helm-version VERSION      Default: v3.21.4
  --e2e-type TYPE             Candidate E2E_TYPE; default: SCHEDULINGGATES
  --benchmark-scenario NAME   Default: gang
  --benchmark-profile PATH    Candidate-relative profile; default:
                              benchmark/testcases/gang/cases/comprehensive.yaml
  --benchmark-rounds N        Default: 3

Image-list maintenance:
  --set-image KEY=IMAGE       Replace one maintained image (repeatable)
  --add-image IMAGE           Add a Candidate-specific image (repeatable)
  --node-image IMAGE          Shorthand for --set-image kind-node=IMAGE
  --list-images               Resolve selection and print images without pulling

Known image keys:
  kind-node, go-builder, runtime-base, e2e-busybox, e2e-nginx,
  benchmark-busybox, kwok

Output and publication:
  --split-size SIZE           Optional split size accepted by split(1), e.g. 1900m
  --publish REPOSITORY        Upload with gh, e.g. owner/repository
  --release-tag TAG           Required together with --publish
  --keep-work-dir             Keep temporary staging after failure/success
  -h, --help

The script inherits HTTP_PROXY/HTTPS_PROXY/NO_PROXY from the server. It does
not require proxy placeholders. The generated bundle contains only
volcano-v4-deploy.sh, bundle.meta, images.tar.gz and SHA256SUMS.
EOF
}

valid_semver() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_mode() { [[ "$1" == "e2e" || "$1" == "benchmark" || "$1" == "both" ]]; }
valid_text() {
  [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *'|'* ]]
}

VOLCANO_REPO="$DEFAULT_VOLCANO_REPO"
VOLCANO_REF=""
K8S_VERSION=""
KIND_VERSION="$DEFAULT_KIND_VERSION"
HELM_VERSION="$DEFAULT_HELM_VERSION"
MODE=""
OUTPUT_DIR=""
E2E_TYPE="SCHEDULINGGATES"
BENCHMARK_SCENARIO="gang"
BENCHMARK_PROFILE="benchmark/testcases/gang/cases/comprehensive.yaml"
BENCHMARK_ROUNDS=3
NODE_IMAGE_OVERRIDE=""
LIST_IMAGES=false
SPLIT_SIZE=""
PUBLISH_REPO=""
RELEASE_TAG=""
KEEP_WORK_DIR=false
OVERRIDES=()
ADDITIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s-version) K8S_VERSION="${2:-}"; shift 2 ;;
    --volcano-repo) VOLCANO_REPO="${2:-}"; shift 2 ;;
    --volcano-ref) VOLCANO_REF="${2:-}"; shift 2 ;;
    --kind-version) KIND_VERSION="${2:-}"; shift 2 ;;
    --helm-version) HELM_VERSION="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --e2e-type) E2E_TYPE="${2:-}"; shift 2 ;;
    --benchmark-scenario) BENCHMARK_SCENARIO="${2:-}"; shift 2 ;;
    --benchmark-profile) BENCHMARK_PROFILE="${2:-}"; shift 2 ;;
    --benchmark-rounds) BENCHMARK_ROUNDS="${2:-}"; shift 2 ;;
    --set-image) OVERRIDES+=("${2:-}"); shift 2 ;;
    --add-image) ADDITIONS+=("${2:-}"); shift 2 ;;
    --node-image) NODE_IMAGE_OVERRIDE="${2:-}"; shift 2 ;;
    --list-images) LIST_IMAGES=true; shift ;;
    --split-size) SPLIT_SIZE="${2:-}"; shift 2 ;;
    --publish) PUBLISH_REPO="${2:-}"; shift 2 ;;
    --release-tag) RELEASE_TAG="${2:-}"; shift 2 ;;
    --keep-work-dir) KEEP_WORK_DIR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$K8S_VERSION" ]] || die "--k8s-version is required"
[[ -n "$VOLCANO_REF" ]] || die "--volcano-ref is required"
[[ -n "$MODE" ]] || die "--mode is required"
[[ -n "$OUTPUT_DIR" || "$LIST_IMAGES" == true ]] || die "--output is required"
valid_semver "$K8S_VERSION" || die "--k8s-version must be exact vMAJOR.MINOR.PATCH"
valid_semver "$KIND_VERSION" || die "--kind-version must be exact vMAJOR.MINOR.PATCH"
valid_semver "$HELM_VERSION" || die "--helm-version must be exact vMAJOR.MINOR.PATCH"
valid_mode "$MODE" || die "--mode must be e2e, benchmark or both"
[[ "$BENCHMARK_ROUNDS" =~ ^[1-9][0-9]*$ ]] || die "--benchmark-rounds must be positive"
valid_text "$VOLCANO_REPO" || die "invalid --volcano-repo"
valid_text "$VOLCANO_REF" || die "invalid --volcano-ref"
valid_text "$E2E_TYPE" || die "invalid --e2e-type"
valid_text "$BENCHMARK_SCENARIO" || die "invalid --benchmark-scenario"
valid_text "$BENCHMARK_PROFILE" || die "invalid --benchmark-profile"
if [[ -n "$PUBLISH_REPO" && -z "$RELEASE_TAG" ]]; then
  die "--release-tag is required with --publish"
fi

IMAGE_KEYS=()
IMAGE_REFS=()
set_image() {
  local key="$1" ref="$2" index
  [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid image key: $key"
  valid_text "$ref" || die "invalid image reference for $key"
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    if [[ "${IMAGE_KEYS[$index]}" == "$key" ]]; then
      IMAGE_REFS[index]="$ref"
      return
    fi
  done
  IMAGE_KEYS+=("$key")
  IMAGE_REFS+=("$ref")
}

# Maintained defaults. Future Candidate base-image changes require updating
# these lines or passing --set-image; the script intentionally does not grow a
# dependency-discovery framework.
set_image kind-node "kindest/node:${K8S_VERSION}"
set_image go-builder "$DEFAULT_GO_BUILDER"
set_image runtime-base "$DEFAULT_RUNTIME_BASE"
if [[ "$MODE" == "e2e" || "$MODE" == "both" ]]; then
  set_image e2e-busybox "$DEFAULT_E2E_BUSYBOX"
  set_image e2e-nginx "$DEFAULT_E2E_NGINX"
fi
if [[ "$MODE" == "benchmark" || "$MODE" == "both" ]]; then
  set_image benchmark-busybox "$DEFAULT_E2E_BUSYBOX"
  set_image kwok "$DEFAULT_KWOK_IMAGE"
fi
[[ -z "$NODE_IMAGE_OVERRIDE" ]] || set_image kind-node "$NODE_IMAGE_OVERRIDE"

for override in "${OVERRIDES[@]}"; do
  [[ "$override" == *=* ]] || die "--set-image expects KEY=IMAGE: $override"
  key="${override%%=*}"
  ref="${override#*=}"
  [[ -n "$key" && -n "$ref" ]] || die "invalid --set-image: $override"
  found=false
  for existing_key in "${IMAGE_KEYS[@]}"; do [[ "$existing_key" == "$key" ]] && found=true; done
  [[ "$found" == true ]] || die "--set-image key is not selected for mode $MODE: $key; use --add-image for a new image"
  set_image "$key" "$ref"
done
for ((index=0; index<${#ADDITIONS[@]}; index++)); do
  set_image "extra-$((index+1))" "${ADDITIONS[$index]}"
done

if [[ "$LIST_IMAGES" == true ]]; then
  printf 'mode=%s\nkubernetes=%s\nkind=%s\n' "$MODE" "$K8S_VERSION" "$KIND_VERSION"
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    printf '%s=%s\n' "${IMAGE_KEYS[$index]}" "${IMAGE_REFS[$index]}"
  done
  exit 0
fi

for command in docker git tar gzip sha256sum awk sed sort mktemp; do need "$command"; done
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || \
  die "packaging requires Linux x86_64"

resolve_commit() {
  local repo="$1" ref="$2" result=""
  if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf '%s\n' "${ref,,}"
    return
  fi
  result="$(git ls-remote "$repo" "refs/tags/${ref}^{}" | awk 'NR==1 {print $1}')"
  [[ -n "$result" ]] || result="$(git ls-remote "$repo" "refs/heads/${ref}" | awk 'NR==1 {print $1}')"
  [[ -n "$result" ]] || result="$(git ls-remote "$repo" "refs/tags/${ref}" | awk 'NR==1 {print $1}')"
  [[ -n "$result" ]] || result="$(git ls-remote "$repo" "$ref" | awk 'NR==1 {print $1}')"
  [[ "$result" =~ ^[0-9a-fA-F]{40}$ ]] || die "cannot resolve Volcano ref: $ref"
  printf '%s\n' "${result,,}"
}

VOLCANO_COMMIT="$(resolve_commit "$VOLCANO_REPO" "$VOLCANO_REF")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
safe_k8s="${K8S_VERSION#v}"
safe_mode="${MODE//[^a-zA-Z0-9._-]/-}"
BUNDLE_NAME="volcano-v4-${safe_k8s}-${VOLCANO_COMMIT:0:12}-${safe_mode}"
BUNDLE_PATH="${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz"
[[ ! -e "$BUNDLE_PATH" ]] || die "output already exists: $BUNDLE_PATH"
WORK_DIR="$(mktemp -d "${OUTPUT_DIR}/.vpg4-package.XXXXXX")"
cleanup() {
  status=$?
  if [[ "$KEEP_WORK_DIR" == true ]]; then
    log "kept staging directory: $WORK_DIR"
  else
    rm -rf -- "$WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT
STAGE="${WORK_DIR}/${BUNDLE_NAME}"
mkdir -p "$STAGE"
DEPLOY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/volcano-v4-deploy.sh"
[[ -f "$DEPLOY_SCRIPT" ]] || die "deploy script is missing next to package script"
cp "$DEPLOY_SCRIPT" "$STAGE/volcano-v4-deploy.sh"
chmod 0755 "$STAGE/volcano-v4-deploy.sh"

META="$STAGE/bundle.meta"
{
  printf 'FORMAT=volcano-performance-guard-v4\n'
  printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
  printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'PLATFORM=linux/amd64\n'
  printf 'K8S_VERSION=%s\n' "$K8S_VERSION"
  printf 'KIND_VERSION=%s\n' "$KIND_VERSION"
  printf 'HELM_VERSION=%s\n' "$HELM_VERSION"
  printf 'VOLCANO_REPO=%s\n' "$VOLCANO_REPO"
  printf 'VOLCANO_REF=%s\n' "$VOLCANO_REF"
  printf 'VOLCANO_COMMIT=%s\n' "$VOLCANO_COMMIT"
  printf 'MODE=%s\n' "$MODE"
  printf 'E2E_TYPE=%s\n' "$E2E_TYPE"
  printf 'BENCHMARK_SCENARIO=%s\n' "$BENCHMARK_SCENARIO"
  printf 'BENCHMARK_PROFILE=%s\n' "$BENCHMARK_PROFILE"
  printf 'BENCHMARK_ROUNDS=%s\n' "$BENCHMARK_ROUNDS"
} > "$META"

SAVE_REFS=()
PULLED_REFS=()
append_unique() {
  local candidate="$1" existing
  for existing in "${SAVE_REFS[@]}"; do [[ "$existing" == "$candidate" ]] && return; done
  SAVE_REFS+=("$candidate")
}
pull_once() {
  local candidate="$1" existing
  for existing in "${PULLED_REFS[@]}"; do [[ "$existing" == "$candidate" ]] && return; done
  docker pull --platform linux/amd64 "$candidate"
  PULLED_REFS+=("$candidate")
}

for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
  key="${IMAGE_KEYS[$index]}"
  pull_ref="${IMAGE_REFS[$index]}"
  log "pulling [$key] $pull_ref"
  pull_once "$pull_ref"
  inspect="$(docker image inspect --format '{{.Os}}/{{.Architecture}}|{{.Id}}|{{join .RepoDigests ","}}' "$pull_ref")"
  platform="${inspect%%|*}"
  remainder="${inspect#*|}"
  image_id="${remainder%%|*}"
  repo_digests="${remainder#*|}"
  [[ "$platform" == "linux/amd64" ]] || die "image platform mismatch for $pull_ref: $platform"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid image ID for $pull_ref"
  save_ref="${pull_ref%@*}"
  if [[ "$pull_ref" == *@* ]]; then
    docker tag "$pull_ref" "$save_ref"
  fi
  docker image inspect "$save_ref" >/dev/null 2>&1 || die "image has no saveable local tag: $save_ref"
  append_unique "$save_ref"
  printf 'IMAGE=%s|%s|%s|%s|%s\n' "$key" "$pull_ref" "$save_ref" "$image_id" "$repo_digests" >> "$META"
done

log "saving ${#SAVE_REFS[@]} local images"
docker image save "${SAVE_REFS[@]}" | gzip -1 -n > "$STAGE/images.tar.gz"
[[ -s "$STAGE/images.tar.gz" ]] || die "image archive is empty"
(
  cd "$STAGE"
  sha256sum bundle.meta images.tar.gz volcano-v4-deploy.sh > SHA256SUMS
)
tar -C "$WORK_DIR" -czf "$BUNDLE_PATH" "$BUNDLE_NAME"
(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$BUNDLE_PATH")" > "$(basename "$BUNDLE_PATH").sha256"
)
log "bundle created: $BUNDLE_PATH"
log "bundle SHA256: $(awk '{print $1}' "${BUNDLE_PATH}.sha256")"

UPLOAD_ASSETS=("$BUNDLE_PATH" "${BUNDLE_PATH}.sha256")
if [[ -n "$SPLIT_SIZE" ]]; then
  need split
  split -b "$SPLIT_SIZE" -d -a 3 "$BUNDLE_PATH" "${BUNDLE_PATH}.part-"
  (
    cd "$OUTPUT_DIR"
    sha256sum "$(basename "$BUNDLE_PATH").part-"* > "$(basename "$BUNDLE_PATH").parts.sha256"
  )
  UPLOAD_ASSETS=("${BUNDLE_PATH}.part-"* "${BUNDLE_PATH}.parts.sha256")
  log "split assets created with size $SPLIT_SIZE"
fi

if [[ -n "$PUBLISH_REPO" ]]; then
  need gh
  if ! gh release view "$RELEASE_TAG" --repo "$PUBLISH_REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" --repo "$PUBLISH_REPO" --title "$RELEASE_TAG" \
      --notes "Volcano v4 dependency bundle ${BUNDLE_NAME}"
  fi
  gh release upload "$RELEASE_TAG" "${UPLOAD_ASSETS[@]}" --repo "$PUBLISH_REPO" --clobber
  log "uploaded to GitHub Release: $PUBLISH_REPO $RELEASE_TAG"
else
  log "upload manually or run: gh release upload TAG '$BUNDLE_PATH' '${BUNDLE_PATH}.sha256' --repo OWNER/REPO"
fi
