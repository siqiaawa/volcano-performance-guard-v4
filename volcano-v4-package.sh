#!/usr/bin/env bash
# External-server entrypoint: download a small maintained image set and the
# exact test tools, then create one transport bundle. No Volcano source, E2E
# code, Benchmark code or module cache is stored in the bundle.
set -Eeuo pipefail

SCRIPT_VERSION="v4.1.1"
DEFAULT_VOLCANO_REPO="https://github.com/volcano-sh/volcano.git"
DEFAULT_KIND_VERSION="v0.32.0"
DEFAULT_HELM_VERSION="v3.21.4"
DEFAULT_GOPROXY="https://proxy.golang.org,direct"
DEFAULT_GOSUMDB="sum.golang.org"
JQ_VERSION="jq-1.8.2"
JQ_SHA256="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"
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
  --goproxy VALUE             Go module source used to build packaged Ginkgo
  --gosumdb VALUE             Go checksum database used to build Ginkgo
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
not require proxy placeholders. The generated bundle contains
volcano-v4-deploy.sh, bundle.meta, images.tar.gz, tools.tar.gz and SHA256SUMS.
tools.tar.gz contains exact linux/amd64 Kind, kubectl, Helm, jq, Go and
Candidate-defined Ginkgo.
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
GOPROXY_VALUE="${GOPROXY:-$DEFAULT_GOPROXY}"
GOSUMDB_VALUE="${GOSUMDB:-$DEFAULT_GOSUMDB}"
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
    --goproxy) GOPROXY_VALUE="${2:-}"; shift 2 ;;
    --gosumdb) GOSUMDB_VALUE="${2:-}"; shift 2 ;;
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
valid_text "$GOPROXY_VALUE" || die "invalid --goproxy"
valid_text "$GOSUMDB_VALUE" || die "invalid --gosumdb"
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

for command in curl docker git tar gzip sha256sum awk sed sort mktemp; do need "$command"; done
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

# Fetch only enough Candidate metadata to lock its host Go and Ginkgo tools.
# Public GitHub repositories use one commit-addressed raw file; other URLs
# fall back to a temporary shallow fetch. Neither path is copied to the bundle.
META_CHECKOUT="$WORK_DIR/candidate-meta"
CANDIDATE_GO_MOD="$WORK_DIR/candidate.go.mod"
log "reading Candidate tool versions from exact commit $VOLCANO_COMMIT"
raw_loaded=false
if [[ "$VOLCANO_REPO" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
  github_owner="${BASH_REMATCH[1]}"
  github_repo="${BASH_REMATCH[2]%.git}"
  if curl --fail --location --retry 1 --connect-timeout 10 --max-time 20 \
    -o "${CANDIDATE_GO_MOD}.part" \
    "https://raw.githubusercontent.com/${github_owner}/${github_repo}/${VOLCANO_COMMIT}/go.mod"; then
    mv "${CANDIDATE_GO_MOD}.part" "$CANDIDATE_GO_MOD"
    raw_loaded=true
  else
    rm -f "${CANDIDATE_GO_MOD}.part"
    log "raw Candidate metadata unavailable; falling back to a shallow Git fetch"
  fi
fi
if [[ "$raw_loaded" != true ]]; then
  git init "$META_CHECKOUT" >/dev/null
  git -C "$META_CHECKOUT" remote add origin "$VOLCANO_REPO"
  git -C "$META_CHECKOUT" fetch --depth 1 origin "$VOLCANO_COMMIT"
  git -C "$META_CHECKOUT" show FETCH_HEAD:go.mod > "$CANDIDATE_GO_MOD"
fi
[[ -s "$CANDIDATE_GO_MOD" ]] || die "Candidate go.mod is empty"

GO_DIRECTIVE="$(awk '$1=="go" && NF==2 {print $2; exit}' "$CANDIDATE_GO_MOD")"
GO_TOOLCHAIN="$(awk '$1=="toolchain" && NF==2 {print $2; exit}' "$CANDIDATE_GO_MOD")"
if [[ -z "$GO_TOOLCHAIN" ]]; then GO_TOOLCHAIN="go${GO_DIRECTIVE}"; fi
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Candidate has no usable Go version"
if [[ ! "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  builder_go=""
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    if [[ "${IMAGE_KEYS[$index]}" == "go-builder" && "${IMAGE_REFS[$index]}" =~ golang:([0-9]+\.[0-9]+\.[0-9]+) ]]; then
      builder_go="${BASH_REMATCH[1]}"
    fi
  done
  if [[ -n "$builder_go" && "$builder_go" == "${GO_TOOLCHAIN#go}."* ]]; then
    GO_TOOLCHAIN="go${builder_go}"
  fi
fi
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die "Candidate Go version has no patch component; use an exact go-builder image"

GINKGO_VERSION="$(awk '$1=="github.com/onsi/ginkgo/v2" {print $2; exit} $1=="require" && $2=="github.com/onsi/ginkgo/v2" {print $3; exit}' "$CANDIDATE_GO_MOD")"
[[ "$GINKGO_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "Candidate does not lock Ginkgo v2"

TOOLS_STAGE="$WORK_DIR/tools"
TOOLS_BIN="$TOOLS_STAGE/bin"
mkdir -p "$TOOLS_BIN"
download_verified() {
  local url="$1" checksum_url="$2" destination="$3" expected actual
  expected="$(curl --fail --location --retry 3 --silent --show-error "$checksum_url" | awk 'NR==1 {print $1}')"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid upstream checksum: $checksum_url"
  curl --fail --location --retry 3 --connect-timeout 30 -o "${destination}.part" "$url"
  actual="$(sha256sum "${destination}.part" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "download hash mismatch: $url"
  mv "${destination}.part" "$destination"
}

log "downloading exact Kind $KIND_VERSION"
download_verified \
  "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
  "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64.sha256sum" \
  "$TOOLS_BIN/kind"
log "downloading exact kubectl $K8S_VERSION"
download_verified \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256" \
  "$TOOLS_BIN/kubectl"
log "downloading exact Helm $HELM_VERSION"
helm_archive="$WORK_DIR/helm.tar.gz"
download_verified \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
  "$helm_archive"
tar -xzf "$helm_archive" -C "$WORK_DIR"
mv "$WORK_DIR/linux-amd64/helm" "$TOOLS_BIN/helm"
rm -rf -- "$WORK_DIR/linux-amd64" "$helm_archive"
log "downloading exact jq $JQ_VERSION"
curl --fail --location --retry 3 --connect-timeout 30 -o "$TOOLS_BIN/jq.part" \
  "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64"
[[ "$(sha256sum "$TOOLS_BIN/jq.part" | awk '{print $1}')" == "$JQ_SHA256" ]] || die "jq hash mismatch"
mv "$TOOLS_BIN/jq.part" "$TOOLS_BIN/jq"
chmod 0755 "$TOOLS_BIN/kind" "$TOOLS_BIN/kubectl" "$TOOLS_BIN/helm" "$TOOLS_BIN/jq"

log "downloading Candidate Go toolchain $GO_TOOLCHAIN"
go_filename="${GO_TOOLCHAIN}.linux-amd64.tar.gz"
go_archive="$WORK_DIR/$go_filename"
go_release_index="$WORK_DIR/go-releases.json"
curl --fail --location --retry 3 --connect-timeout 30 \
  -o "$go_release_index" 'https://go.dev/dl/?mode=json&include=all'
# The dollar-prefixed names below are jq variables, not shell expansions.
# shellcheck disable=SC2016
go_expected_sha="$("$TOOLS_BIN/jq" -r --arg version "$GO_TOOLCHAIN" --arg filename "$go_filename" '
  .[] | select(.version == $version) | .files[] |
  select(.filename == $filename and .os == "linux" and .arch == "amd64" and .kind == "archive") |
  .sha256
' "$go_release_index" | head -n 1)"
[[ "$go_expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "Go release is absent from the official download index: $GO_TOOLCHAIN"
if ! curl --fail --location --retry 3 --connect-timeout 30 \
  -o "${go_archive}.part" "https://dl.google.com/go/${go_filename}"; then
  rm -f "${go_archive}.part"
  log "direct Go storage download failed; retrying through go.dev"
  curl --fail --location --retry 3 --connect-timeout 30 \
    -o "${go_archive}.part" "https://go.dev/dl/${go_filename}"
fi
go_actual_sha="$(sha256sum "${go_archive}.part" | awk '{print $1}')"
[[ "${go_actual_sha,,}" == "${go_expected_sha,,}" ]] || die "Go toolchain hash mismatch: $GO_TOOLCHAIN"
mv "${go_archive}.part" "$go_archive"
tar -xzf "$go_archive" -C "$TOOLS_STAGE"
rm -f "$go_archive" "$go_release_index"

export GOROOT="$TOOLS_STAGE/go"
export GOTOOLCHAIN=local
export GOPROXY="$GOPROXY_VALUE"
export GOSUMDB="$GOSUMDB_VALUE"
export GOPATH="$WORK_DIR/tool-gopath"
export GOMODCACHE="$WORK_DIR/tool-go-mod-cache"
export GOCACHE="$WORK_DIR/tool-go-build-cache"
export PATH="$GOROOT/bin:$TOOLS_BIN:$PATH"
log "building Candidate-defined Ginkgo $GINKGO_VERSION"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOBIN="$TOOLS_BIN" \
  go install "github.com/onsi/ginkgo/v2/ginkgo@${GINKGO_VERSION}"
chmod 0755 "$TOOLS_BIN/ginkgo"

"$TOOLS_BIN/kind" version | grep -F "$KIND_VERSION" >/dev/null || die "downloaded Kind version mismatch"
kubectl_client_version="$("$TOOLS_BIN/kubectl" version --client -o json | "$TOOLS_BIN/jq" -r '.clientVersion.gitVersion')"
[[ "$kubectl_client_version" == "$K8S_VERSION" ]] || die "downloaded kubectl version mismatch"
"$TOOLS_BIN/helm" version --short | grep -F "$HELM_VERSION" >/dev/null || die "downloaded Helm version mismatch"
[[ "$("$TOOLS_BIN/jq" --version)" == "$JQ_VERSION" ]] || die "downloaded jq version mismatch"
"$GOROOT/bin/go" version | grep -F " $GO_TOOLCHAIN " >/dev/null || die "downloaded Go version mismatch"
"$TOOLS_BIN/ginkgo" version | grep -F "${GINKGO_VERSION#v}" >/dev/null || die "built Ginkgo version mismatch"

tar -C "$TOOLS_STAGE" -czf "$STAGE/tools.tar.gz" .
[[ -s "$STAGE/tools.tar.gz" ]] || die "tool archive is empty"

META="$STAGE/bundle.meta"
{
  printf 'FORMAT=volcano-performance-guard-v4\n'
  printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
  printf 'CREATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'PLATFORM=linux/amd64\n'
  printf 'K8S_VERSION=%s\n' "$K8S_VERSION"
  printf 'KIND_VERSION=%s\n' "$KIND_VERSION"
  printf 'HELM_VERSION=%s\n' "$HELM_VERSION"
  printf 'JQ_VERSION=%s\n' "$JQ_VERSION"
  printf 'GO_TOOLCHAIN=%s\n' "$GO_TOOLCHAIN"
  printf 'GINKGO_VERSION=%s\n' "$GINKGO_VERSION"
  printf 'VOLCANO_REPO=%s\n' "$VOLCANO_REPO"
  printf 'VOLCANO_REF=%s\n' "$VOLCANO_REF"
  printf 'VOLCANO_COMMIT=%s\n' "$VOLCANO_COMMIT"
  printf 'MODE=%s\n' "$MODE"
  printf 'E2E_TYPE=%s\n' "$E2E_TYPE"
  printf 'BENCHMARK_SCENARIO=%s\n' "$BENCHMARK_SCENARIO"
  printf 'BENCHMARK_PROFILE=%s\n' "$BENCHMARK_PROFILE"
  printf 'BENCHMARK_ROUNDS=%s\n' "$BENCHMARK_ROUNDS"
  printf 'TOOL=kind|%s|bin/kind|%s\n' "$KIND_VERSION" "$(sha256sum "$TOOLS_BIN/kind" | awk '{print $1}')"
  printf 'TOOL=kubectl|%s|bin/kubectl|%s\n' "$K8S_VERSION" "$(sha256sum "$TOOLS_BIN/kubectl" | awk '{print $1}')"
  printf 'TOOL=helm|%s|bin/helm|%s\n' "$HELM_VERSION" "$(sha256sum "$TOOLS_BIN/helm" | awk '{print $1}')"
  printf 'TOOL=jq|%s|bin/jq|%s\n' "$JQ_VERSION" "$(sha256sum "$TOOLS_BIN/jq" | awk '{print $1}')"
  printf 'TOOL=go|%s|go/bin/go|%s\n' "$GO_TOOLCHAIN" "$(sha256sum "$TOOLS_STAGE/go/bin/go" | awk '{print $1}')"
  printf 'TOOL=ginkgo|%s|bin/ginkgo|%s\n' "$GINKGO_VERSION" "$(sha256sum "$TOOLS_BIN/ginkgo" | awk '{print $1}')"
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
  # Older Docker releases expose RepoDigests as []interface{} instead of
  # []string, which makes the Go-template join helper fail. RepoDigests are
  # not used for restore validation, so keep the portable platform and image
  # ID fields and leave the reserved metadata field unset.
  inspect="$(docker image inspect --format '{{.Os}}/{{.Architecture}}|{{.Id}}' "$pull_ref")"
  platform="${inspect%%|*}"
  image_id="${inspect#*|}"
  [[ "$platform" == "linux/amd64" ]] || die "image platform mismatch for $pull_ref: $platform"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid image ID for $pull_ref"
  save_ref="${pull_ref%@*}"
  if [[ "$pull_ref" == *@* ]]; then
    docker tag "$pull_ref" "$save_ref"
  fi
  docker image inspect "$save_ref" >/dev/null 2>&1 || die "image has no saveable local tag: $save_ref"
  append_unique "$save_ref"
  printf 'IMAGE=%s|%s|%s|%s|-\n' "$key" "$pull_ref" "$save_ref" "$image_id" >> "$META"
done

log "saving ${#SAVE_REFS[@]} local images"
docker image save "${SAVE_REFS[@]}" | gzip -1 -n > "$STAGE/images.tar.gz"
[[ -s "$STAGE/images.tar.gz" ]] || die "image archive is empty"
(
  cd "$STAGE"
  sha256sum bundle.meta images.tar.gz tools.tar.gz volcano-v4-deploy.sh > SHA256SUMS
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
