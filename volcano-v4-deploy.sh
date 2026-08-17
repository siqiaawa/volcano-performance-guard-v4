#!/usr/bin/env bash
# Internal-server entrypoint: load ordinary Docker images, fetch the exact
# Candidate source, build it with its own Dockerfiles and invoke its own E2E or
# Benchmark code. No Python or project-specific helper binary is required.
set -Eeuo pipefail

SCRIPT_VERSION="v4.0.0"
DEFAULT_GOPROXY="https://proxy.golang.org,direct"
DEFAULT_GOSUMDB="sum.golang.org"
JQ_VERSION="jq-1.8.2"
JQ_SHA256="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"

log() { printf '[vpg4-deploy] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

usage() {
  cat <<'EOF'
Usage:
  bash volcano-v4-deploy.sh --bundle FILE_OR_DIR [options]
  bash volcano-v4-deploy.sh --bundle-url URL [options]

When the script is run from an extracted bundle containing bundle.meta,
--bundle is optional.

Input/output:
  --bundle PATH               Bundle .tar.gz, extracted bundle dir, or part-000
  --bundle-url URL            Download one unsplit bundle with curl
  --output DIR                Result directory; default: ./volcano-v4-results-TIME
  --work-dir DIR              Persistent work directory instead of a temporary one
  --keep-work-dir             Keep an automatically created work directory
  --keep-cluster              Keep the last project Kind cluster

Optional selection overrides:
  --mode e2e|benchmark|both
  --e2e-type TYPE
  --benchmark-scenario NAME
  --benchmark-profile PATH
  --benchmark-rounds N
  --cluster-prefix NAME       Default: volcano-v4
  --goproxy VALUE             Default: inherited GOPROXY or public Go default
  --gosumdb VALUE             Default: inherited GOSUMDB or sum.golang.org

The server needs Bash, curl, git, Docker, tar, gzip, sha256sum, make and basic
POSIX utilities. Exact Kind, kubectl, Helm, jq, Go and Ginkgo are placed under
the work directory automatically. Nothing is installed system-wide.
EOF
}

valid_semver() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_mode() { [[ "$1" == "e2e" || "$1" == "benchmark" || "$1" == "both" ]]; }
valid_text() { [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *'|'* ]]; }

BUNDLE_INPUT=""
BUNDLE_URL=""
OUTPUT_DIR=""
WORK_DIR=""
KEEP_WORK_DIR=false
KEEP_CLUSTER=false
MODE_OVERRIDE=""
E2E_TYPE_OVERRIDE=""
BENCHMARK_SCENARIO_OVERRIDE=""
BENCHMARK_PROFILE_OVERRIDE=""
BENCHMARK_ROUNDS_OVERRIDE=""
CLUSTER_PREFIX="volcano-v4"
GOPROXY_VALUE="${GOPROXY:-$DEFAULT_GOPROXY}"
GOSUMDB_VALUE="${GOSUMDB:-$DEFAULT_GOSUMDB}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_INPUT="${2:-}"; shift 2 ;;
    --bundle-url) BUNDLE_URL="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --keep-work-dir) KEEP_WORK_DIR=true; shift ;;
    --keep-cluster) KEEP_CLUSTER=true; shift ;;
    --mode) MODE_OVERRIDE="${2:-}"; shift 2 ;;
    --e2e-type) E2E_TYPE_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-scenario) BENCHMARK_SCENARIO_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-profile) BENCHMARK_PROFILE_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-rounds) BENCHMARK_ROUNDS_OVERRIDE="${2:-}"; shift 2 ;;
    --cluster-prefix) CLUSTER_PREFIX="${2:-}"; shift 2 ;;
    --goproxy) GOPROXY_VALUE="${2:-}"; shift 2 ;;
    --gosumdb) GOSUMDB_VALUE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ -z "$BUNDLE_INPUT" || -z "$BUNDLE_URL" ]] || die "use only one of --bundle and --bundle-url"
[[ "$CLUSTER_PREFIX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid --cluster-prefix"
[[ -z "$MODE_OVERRIDE" ]] || valid_mode "$MODE_OVERRIDE" || die "invalid --mode"
[[ -z "$BENCHMARK_ROUNDS_OVERRIDE" || "$BENCHMARK_ROUNDS_OVERRIDE" =~ ^[1-9][0-9]*$ ]] || \
  die "--benchmark-rounds must be positive"

for command in curl git docker tar gzip sha256sum awk sed grep sort mktemp make tee; do need "$command"; done
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || die "deployment requires Linux x86_64"

if [[ -z "$OUTPUT_DIR" ]]; then OUTPUT_DIR="./volcano-v4-results-$(date -u +%Y%m%d-%H%M%S)"; fi
[[ ! -e "$OUTPUT_DIR" ]] || die "output already exists: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

AUTO_WORK=false
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d /tmp/volcano-v4-deploy.XXXXXX)"
  AUTO_WORK=true
else
  [[ ! -e "$WORK_DIR" ]] || die "work directory already exists: $WORK_DIR"
  mkdir -p "$WORK_DIR"
  WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
fi
CURRENT_CLUSTER=""
CLUSTER_CREATED=false
cleanup() {
  status=$?
  if [[ "$CLUSTER_CREATED" == true && "$KEEP_CLUSTER" != true && -n "$CURRENT_CLUSTER" ]]; then
    log "deleting project cluster: $CURRENT_CLUSTER"
    kind delete cluster --name "$CURRENT_CLUSTER" >"$OUTPUT_DIR/kind-delete-trap.log" 2>&1 || true
  fi
  if [[ "$AUTO_WORK" == true && "$KEEP_WORK_DIR" != true ]]; then
    rm -rf -- "$WORK_DIR"
  else
    log "kept work directory: $WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ -n "$BUNDLE_URL" ]]; then
  BUNDLE_INPUT="$WORK_DIR/downloaded-bundle.tar.gz"
  log "downloading bundle"
  curl --fail --location --retry 3 --connect-timeout 30 -o "$BUNDLE_INPUT" "$BUNDLE_URL"
fi
if [[ -z "$BUNDLE_INPUT" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  [[ -f "$script_dir/bundle.meta" ]] || die "--bundle is required outside an extracted bundle"
  BUNDLE_INPUT="$script_dir"
fi

safe_extract_bundle() {
  local archive="$1" destination="$2" entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" != /* && "$entry" != ../* && "$entry" != *'/../'* ]] || \
      die "unsafe path in bundle archive: $entry"
  done < <(tar -tzf "$archive")
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination" --no-same-owner --no-same-permissions
}

if [[ -d "$BUNDLE_INPUT" ]]; then
  BUNDLE_ROOT="$(cd "$BUNDLE_INPUT" && pwd -P)"
else
  [[ -f "$BUNDLE_INPUT" ]] || die "bundle does not exist: $BUNDLE_INPUT"
  if [[ "$BUNDLE_INPUT" == *.part-[0-9][0-9][0-9] ]]; then
    prefix="${BUNDLE_INPUT%.part-*}"
    part_dir="$(cd "$(dirname "$BUNDLE_INPUT")" && pwd -P)"
    [[ -f "${prefix}.parts.sha256" ]] || die "split checksum manifest is missing: ${prefix}.parts.sha256"
    (cd "$part_dir" && sha256sum -c "$(basename "${prefix}.parts.sha256")")
    combined="$WORK_DIR/reassembled-bundle.tar.gz"
    cat "${prefix}.part-"[0-9][0-9][0-9] > "$combined"
    BUNDLE_INPUT="$combined"
  elif [[ -f "${BUNDLE_INPUT}.sha256" ]]; then
    (cd "$(dirname "$BUNDLE_INPUT")" && sha256sum -c "$(basename "${BUNDLE_INPUT}.sha256")")
  fi
  safe_extract_bundle "$BUNDLE_INPUT" "$WORK_DIR/extracted"
  roots=("$WORK_DIR/extracted"/*)
  [[ ${#roots[@]} -eq 1 && -d "${roots[0]}" ]] || die "bundle must contain exactly one top-level directory"
  BUNDLE_ROOT="${roots[0]}"
fi

for required in bundle.meta images.tar.gz SHA256SUMS volcano-v4-deploy.sh; do
  [[ -f "$BUNDLE_ROOT/$required" ]] || die "bundle is missing $required"
done
(cd "$BUNDLE_ROOT" && sha256sum -c SHA256SUMS)

FORMAT=""; K8S_VERSION=""; KIND_VERSION=""; HELM_VERSION=""; VOLCANO_REPO=""
VOLCANO_REF=""; VOLCANO_COMMIT=""; MODE=""; E2E_TYPE=""; BENCHMARK_SCENARIO=""
BENCHMARK_PROFILE=""; BENCHMARK_ROUNDS=""
IMAGE_KEYS=(); IMAGE_PULL_REFS=(); IMAGE_SAVE_REFS=(); IMAGE_IDS=()
while IFS='=' read -r name value; do
  [[ -n "$name" ]] || continue
  case "$name" in
    FORMAT) FORMAT="$value" ;;
    K8S_VERSION) K8S_VERSION="$value" ;;
    KIND_VERSION) KIND_VERSION="$value" ;;
    HELM_VERSION) HELM_VERSION="$value" ;;
    VOLCANO_REPO) VOLCANO_REPO="$value" ;;
    VOLCANO_REF) VOLCANO_REF="$value" ;;
    VOLCANO_COMMIT) VOLCANO_COMMIT="$value" ;;
    MODE) MODE="$value" ;;
    E2E_TYPE) E2E_TYPE="$value" ;;
    BENCHMARK_SCENARIO) BENCHMARK_SCENARIO="$value" ;;
    BENCHMARK_PROFILE) BENCHMARK_PROFILE="$value" ;;
    BENCHMARK_ROUNDS) BENCHMARK_ROUNDS="$value" ;;
    IMAGE)
      IFS='|' read -r image_key pull_ref save_ref image_id _ <<< "$value"
      IMAGE_KEYS+=("$image_key"); IMAGE_PULL_REFS+=("$pull_ref")
      IMAGE_SAVE_REFS+=("$save_ref"); IMAGE_IDS+=("$image_id")
      ;;
  esac
done < "$BUNDLE_ROOT/bundle.meta"

[[ "$FORMAT" == "volcano-performance-guard-v4" ]] || die "unsupported bundle format"
valid_semver "$K8S_VERSION" || die "invalid K8S version in bundle"
valid_semver "$KIND_VERSION" || die "invalid Kind version in bundle"
valid_semver "$HELM_VERSION" || die "invalid Helm version in bundle"
[[ "$VOLCANO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid Volcano commit in bundle"
valid_mode "$MODE" || die "invalid mode in bundle"
[[ ${#IMAGE_KEYS[@]} -gt 0 ]] || die "bundle has no images"
PACKAGED_MODE="$MODE"
[[ -z "$MODE_OVERRIDE" ]] || MODE="$MODE_OVERRIDE"
[[ -z "$E2E_TYPE_OVERRIDE" ]] || E2E_TYPE="$E2E_TYPE_OVERRIDE"
[[ -z "$BENCHMARK_SCENARIO_OVERRIDE" ]] || BENCHMARK_SCENARIO="$BENCHMARK_SCENARIO_OVERRIDE"
[[ -z "$BENCHMARK_PROFILE_OVERRIDE" ]] || BENCHMARK_PROFILE="$BENCHMARK_PROFILE_OVERRIDE"
[[ -z "$BENCHMARK_ROUNDS_OVERRIDE" ]] || BENCHMARK_ROUNDS="$BENCHMARK_ROUNDS_OVERRIDE"
valid_mode "$MODE" || die "invalid selected mode"
if [[ "$PACKAGED_MODE" != "both" && "$MODE" != "$PACKAGED_MODE" ]]; then
  die "requested mode $MODE is not covered by bundle mode $PACKAGED_MODE"
fi
if [[ "$KEEP_CLUSTER" == true && "$MODE" == "both" ]]; then
  die "--keep-cluster cannot be combined with --mode both"
fi
valid_text "$E2E_TYPE" || die "invalid selected E2E type"
valid_text "$BENCHMARK_SCENARIO" || die "invalid selected Benchmark scenario"
valid_text "$BENCHMARK_PROFILE" || die "invalid selected Benchmark profile"
[[ "$BENCHMARK_ROUNDS" =~ ^[1-9][0-9]*$ ]] || die "invalid Benchmark rounds"

log "loading ordinary Docker images from bundle"
gzip -dc "$BUNDLE_ROOT/images.tar.gz" | docker image load | tee "$OUTPUT_DIR/docker-load.log"
NODE_IMAGE=""
RUNTIME_IMAGES=()
for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
  key="${IMAGE_KEYS[$index]}"; save_ref="${IMAGE_SAVE_REFS[$index]}"; expected_id="${IMAGE_IDS[$index]}"
  observed="$(docker image inspect --format '{{.Os}}/{{.Architecture}}|{{.Id}}' "$save_ref" 2>/dev/null)" || \
    die "loaded image is missing: $save_ref"
  [[ "${observed%%|*}" == "linux/amd64" ]] || die "loaded image platform mismatch: $save_ref"
  [[ "${observed#*|}" == "$expected_id" ]] || die "loaded image ID mismatch: $save_ref"
  if [[ "$key" == "kind-node" ]]; then NODE_IMAGE="$save_ref"; fi
  if [[ "$key" == e2e-* || "$key" == benchmark-* || "$key" == "kwok" || "$key" == extra-* ]]; then
    RUNTIME_IMAGES+=("$save_ref")
  fi
done
[[ -n "$NODE_IMAGE" ]] || die "bundle does not define kind-node"

TOOLS_DIR="$WORK_DIR/tools"
BIN_DIR="$TOOLS_DIR/bin"
mkdir -p "$BIN_DIR"
download_verified() {
  local url="$1" checksum_url="$2" destination="$3" expected actual
  expected="$(curl --fail --location --retry 3 --silent --show-error "$checksum_url" | awk 'NR==1 {print $1}')"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid upstream checksum: $checksum_url"
  curl --fail --location --retry 3 --connect-timeout 30 -o "${destination}.part" "$url"
  actual="$(sha256sum "${destination}.part" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "download hash mismatch: $url"
  mv "${destination}.part" "$destination"
}

log "downloading exact Kind, kubectl, Helm and jq into work directory"
download_verified \
  "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
  "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64.sha256sum" \
  "$BIN_DIR/kind"
download_verified \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256" \
  "$BIN_DIR/kubectl"
helm_archive="$TOOLS_DIR/helm.tar.gz"
download_verified \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
  "$helm_archive"
tar -xzf "$helm_archive" -C "$TOOLS_DIR"
mv "$TOOLS_DIR/linux-amd64/helm" "$BIN_DIR/helm"
rm -rf -- "$TOOLS_DIR/linux-amd64" "$helm_archive"
curl --fail --location --retry 3 --connect-timeout 30 -o "$BIN_DIR/jq.part" \
  "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64"
[[ "$(sha256sum "$BIN_DIR/jq.part" | awk '{print $1}')" == "$JQ_SHA256" ]] || die "jq hash mismatch"
mv "$BIN_DIR/jq.part" "$BIN_DIR/jq"
chmod 0755 "$BIN_DIR/kind" "$BIN_DIR/kubectl" "$BIN_DIR/helm" "$BIN_DIR/jq"
export PATH="$BIN_DIR:$PATH"
kind version | tee "$OUTPUT_DIR/kind-version.log"
kubectl version --client -o json > "$OUTPUT_DIR/kubectl-version.json"
helm version --short | tee "$OUTPUT_DIR/helm-version.log"

CHECKOUT="$WORK_DIR/volcano"
log "fetching exact Volcano commit $VOLCANO_COMMIT"
git init "$CHECKOUT" >/dev/null
git -C "$CHECKOUT" remote add origin "$VOLCANO_REPO"
git -C "$CHECKOUT" fetch --depth 1 origin "$VOLCANO_COMMIT"
git -C "$CHECKOUT" checkout --detach FETCH_HEAD
[[ "$(git -C "$CHECKOUT" rev-parse HEAD)" == "$VOLCANO_COMMIT" ]] || die "Candidate commit mismatch"
git -C "$CHECKOUT" submodule update --init --recursive --depth 1
git -C "$CHECKOUT" status --short > "$OUTPUT_DIR/candidate-status.txt"
printf '%s\n' "$VOLCANO_COMMIT" > "$OUTPUT_DIR/candidate-commit.txt"

GO_DIRECTIVE="$(awk '$1=="go" && NF==2 {print $2; exit}' "$CHECKOUT/go.mod")"
GO_TOOLCHAIN="$(awk '$1=="toolchain" && NF==2 {print $2; exit}' "$CHECKOUT/go.mod")"
if [[ -z "$GO_TOOLCHAIN" ]]; then GO_TOOLCHAIN="go${GO_DIRECTIVE}"; fi
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Candidate has no usable Go version"
if [[ ! "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    if [[ "${IMAGE_KEYS[$index]}" == "go-builder" && "${IMAGE_SAVE_REFS[$index]}" =~ golang:([0-9]+\.[0-9]+\.[0-9]+) ]]; then
      builder_go="${BASH_REMATCH[1]}"
      if [[ "$builder_go" == "${GO_TOOLCHAIN#go}."* ]]; then GO_TOOLCHAIN="go${builder_go}"; fi
    fi
  done
fi
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die "Candidate Go version has no patch component; repack with an exact go-builder image"
go_archive="$TOOLS_DIR/${GO_TOOLCHAIN}.linux-amd64.tar.gz"
log "downloading Candidate Go toolchain $GO_TOOLCHAIN"
go_filename="${GO_TOOLCHAIN}.linux-amd64.tar.gz"
go_release_index="$TOOLS_DIR/go-releases.json"
curl --fail --location --retry 3 --connect-timeout 30 \
  -o "$go_release_index" 'https://go.dev/dl/?mode=json&include=all'
# The dollar-prefixed names below are jq variables, not shell expansions.
# shellcheck disable=SC2016
go_expected_sha="$("$BIN_DIR/jq" -r --arg version "$GO_TOOLCHAIN" --arg filename "$go_filename" '
  .[] | select(.version == $version) | .files[] |
  select(.filename == $filename and .os == "linux" and .arch == "amd64" and .kind == "archive") |
  .sha256
' "$go_release_index" | head -n 1)"
[[ "$go_expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] || die "Go release is absent from the official download index: $GO_TOOLCHAIN"
curl --fail --location --retry 3 --connect-timeout 30 \
  -o "${go_archive}.part" "https://go.dev/dl/${go_filename}"
go_actual_sha="$(sha256sum "${go_archive}.part" | awk '{print $1}')"
[[ "${go_actual_sha,,}" == "${go_expected_sha,,}" ]] || die "Go toolchain hash mismatch: $GO_TOOLCHAIN"
mv "${go_archive}.part" "$go_archive"
tar -xzf "$go_archive" -C "$TOOLS_DIR"
rm -f "$go_archive" "$go_release_index"
export GOROOT="$TOOLS_DIR/go"
export GOTOOLCHAIN=local
export GOPROXY="$GOPROXY_VALUE"
export GOSUMDB="$GOSUMDB_VALUE"
export GOPATH="$WORK_DIR/gopath"
export GOMODCACHE="$WORK_DIR/go-mod-cache"
export GOCACHE="$WORK_DIR/go-build-cache"
export PATH="$GOROOT/bin:$BIN_DIR:$PATH"
go version | tee "$OUTPUT_DIR/go-version.log"
go env GOPROXY GOSUMDB GOTOOLCHAIN GOOS GOARCH > "$OUTPUT_DIR/go-environment.txt"

GINKGO_VERSION="$(awk '$1=="github.com/onsi/ginkgo/v2" {print $2; exit} $1=="require" && $2=="github.com/onsi/ginkgo/v2" {print $3; exit}' "$CHECKOUT/go.mod")"
[[ "$GINKGO_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "Candidate does not lock Ginkgo v2"
log "installing Candidate-defined Ginkgo $GINKGO_VERSION"
GOBIN="$BIN_DIR" go install "github.com/onsi/ginkgo/v2/ginkgo@${GINKGO_VERSION}"
ginkgo version | tee "$OUTPUT_DIR/ginkgo-version.log"

# Local docker-driver builds reuse the images imported above. A separate
# docker-container BuildKit would not share this local image store.
docker buildx inspect default >/dev/null 2>&1 || die "Docker default buildx builder is unavailable"
driver="$(docker buildx inspect default | awk -F': ' '/^Driver:/ {print $2; exit}' | tr -d '[:space:]')"
[[ "$driver" == "docker" ]] || die "default Buildx driver must be docker, got: ${driver:-unknown}"
docker buildx use default
export BUILDX_BUILDER=default

for dockerfile in scheduler controller-manager webhook-manager; do
  path="$CHECKOUT/installer/dockerfile/$dockerfile/Dockerfile"
  [[ -f "$path" ]] || die "Candidate Dockerfile is missing: $path"
  while IFS= read -r base; do
    [[ "$base" != *"\${"* ]] || die "unresolved base image in $path: $base; update --set-image"
    local_ref="${base%@*}"
    docker image inspect "$local_ref" >/dev/null 2>&1 || \
      die "Candidate base image is not bundled: $base; repack with --set-image or --add-image"
  done < <(awk 'toupper($1)=="FROM" {for(i=2;i<=NF;i++) if($i !~ /^--/) {print $i; break}}' "$path" | sort -u)
done

BUILD_TARGETS=(vc-scheduler-image vc-controller-manager-image vc-webhook-manager-image)
if [[ "$MODE" != "benchmark" && "$E2E_TYPE" == AGENTSCHEDULER* ]]; then
  BUILD_TARGETS+=(vc-agent-scheduler-image)
fi
log "building Candidate images with its official Makefile"
(
  cd "$CHECKOUT"
  make "${BUILD_TARGETS[@]}" \
    "TAG=$VOLCANO_COMMIT" IMAGE_PREFIX=volcanosh FORCE_REBUILD=true \
    BUILDX_OUTPUT_TYPE=docker DOCKER_PLATFORMS=linux/amd64
) 2>&1 | tee "$OUTPUT_DIR/candidate-build.log"

CANDIDATE_IMAGES=(
  "volcanosh/vc-scheduler:${VOLCANO_COMMIT}"
  "volcanosh/vc-controller-manager:${VOLCANO_COMMIT}"
  "volcanosh/vc-webhook-manager:${VOLCANO_COMMIT}"
)
if [[ "$E2E_TYPE" == AGENTSCHEDULER* && "$MODE" != "benchmark" ]]; then
  CANDIDATE_IMAGES+=("volcanosh/vc-agent-scheduler:${VOLCANO_COMMIT}")
fi
for image in "${CANDIDATE_IMAGES[@]}"; do
  platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")"
  [[ "$platform" == "linux/amd64" ]] || die "Candidate image platform mismatch: $image: $platform"
done

cluster_exists() {
  local name="$1"
  kind get clusters 2>/dev/null | grep -Fxq "$name"
}

create_cluster() {
  local purpose="$1" name="$2" image
  local config="$WORK_DIR/kind-${purpose}.yaml"
  cluster_exists "$name" && die "project cluster already exists: $name"
  cat > "$config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
  CURRENT_CLUSTER="$name"
  CLUSTER_CREATED=true
  log "creating $purpose cluster $name with $NODE_IMAGE"
  kind create cluster --name "$name" --image "$NODE_IMAGE" --config "$config" --wait 300s \
    2>&1 | tee "$OUTPUT_DIR/kind-create-${purpose}.log"
  kind get kubeconfig --name "$name" > "$OUTPUT_DIR/kubeconfig-${purpose}"
  chmod 0600 "$OUTPUT_DIR/kubeconfig-${purpose}"
  export KUBECONFIG="$OUTPUT_DIR/kubeconfig-${purpose}"
  observed="$("$BIN_DIR/kubectl" version -o json | "$BIN_DIR/jq" -r '.serverVersion.gitVersion')"
  [[ "$observed" == "$K8S_VERSION" ]] || die "Kubernetes version mismatch: expected $K8S_VERSION, got $observed"
  for image in "${CANDIDATE_IMAGES[@]}" "${RUNTIME_IMAGES[@]}"; do
    kind load docker-image "$image" --name "$name" 2>&1 | tee -a "$OUTPUT_DIR/kind-load-${purpose}.log"
  done
}

install_candidate() {
  local purpose="$1"
  local values="$WORK_DIR/values-${purpose}.yaml"
  cat > "$values" <<EOF
basic:
  image_pull_policy: IfNotPresent
  image_tag_version: "$VOLCANO_COMMIT"
  scheduler_config_file: config/volcano-scheduler-ci.conf
  crd_version: v1
custom:
  scheduler_log_level: 5
  scheduler_feature_gates: SchedulingGatesQueueAdmission=true
  admission_feature_gates: SchedulingGatesQueueAdmission=true
  admission_tolerations: &controlPlaneTolerations
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
  controller_tolerations: *controlPlaneTolerations
  scheduler_tolerations: *controlPlaneTolerations
EOF
  helm upgrade --install integration "$CHECKOUT/installer/helm/chart/volcano" \
    --namespace volcano-system --create-namespace --values "$values" \
    --kubeconfig "$KUBECONFIG" --wait --timeout 300s \
    2>&1 | tee "$OUTPUT_DIR/helm-install-${purpose}.log"
  kubectl --kubeconfig "$KUBECONFIG" -n volcano-system get pods -o wide \
    > "$OUTPUT_DIR/volcano-pods-${purpose}.txt"
}

delete_current_cluster() {
  local purpose="$1"
  if [[ "$KEEP_CLUSTER" == true ]]; then
    log "keeping cluster by request: $CURRENT_CLUSTER"
    return
  fi
  kind delete cluster --name "$CURRENT_CLUSTER" 2>&1 | tee "$OUTPUT_DIR/kind-delete-${purpose}.log"
  CLUSTER_CREATED=false
  CURRENT_CLUSTER=""
}

run_e2e() {
  local suffix="${VOLCANO_COMMIT:0:8}"
  local name="${CLUSTER_PREFIX}-${suffix}-e2e"
  name="${name:0:63}"; name="${name%-}"
  create_cluster e2e "$name"
  install_candidate e2e
  log "running Candidate E2E type $E2E_TYPE"
  (
    cd "$CHECKOUT"
    SKIP_CLUSTER_SETUP=1 CLEANUP_CLUSTER=0 CLUSTER_NAME=integration \
      KUBECONFIG="$KUBECONFIG" E2E_TYPE="$E2E_TYPE" OS=linux \
      IMAGE_PREFIX=volcanosh TAG="$VOLCANO_COMMIT" \
      ARTIFACTS_PATH="$OUTPUT_DIR/e2e-artifacts" \
      bash hack/run-e2e-kind.sh
  ) 2>&1 | tee "$OUTPUT_DIR/e2e-${E2E_TYPE}.log"
  delete_current_cluster e2e
}

run_benchmark() {
  local suffix="${VOLCANO_COMMIT:0:8}"
  local name="${CLUSTER_PREFIX}-${suffix}-benchmark"
  local profile="$CHECKOUT/$BENCHMARK_PROFILE" round round_dir kwok_version="v0.7.0"
  name="${name:0:63}"; name="${name%-}"
  [[ -f "$profile" ]] || die "Candidate Benchmark profile does not exist: $BENCHMARK_PROFILE"
  create_cluster benchmark "$name"
  install_candidate benchmark
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    if [[ "${IMAGE_KEYS[$index]}" == "kwok" && "${IMAGE_SAVE_REFS[$index]}" == *:* ]]; then
      kwok_version="v${IMAGE_SAVE_REFS[$index]##*:v}"
    fi
  done
  log "preparing Candidate Benchmark infrastructure"
  (
    cd "$CHECKOUT/benchmark"
    KUBECONFIG="$KUBECONFIG" KWOK_VERSION="$kwok_version" \
      USE_EXISTING_CLUSTER=true SKIP_INSTALL_VOLCANO=true SKIP_INSTALL_MONITORING=true \
      make create-nodes
    if [[ "$BENCHMARK_PROFILE" == *net-topo* ]]; then
      KUBECONFIG="$KUBECONFIG" make create-hypernodes
    fi
  ) 2>&1 | tee "$OUTPUT_DIR/benchmark-infrastructure.log"
  for ((round=1; round<=BENCHMARK_ROUNDS; round++)); do
    printf -v round_dir '%s/benchmark-round-%02d' "$OUTPUT_DIR" "$round"
    mkdir -p "$round_dir"
    log "running Candidate Benchmark round $round/$BENCHMARK_ROUNDS"
    (
      cd "$CHECKOUT/benchmark"
      KUBECONFIG="$KUBECONFIG" USE_EXISTING_CLUSTER=true SKIP_INSTALL_VOLCANO=true \
        SKIP_INSTALL_MONITORING=true DRY_RUN=true \
        bash scripts/run-tests.sh "$BENCHMARK_SCENARIO" "--config=$profile"
      KUBECONFIG="$KUBECONFIG" make collect-pod-latency
      [[ ! -d results ]] || cp -a results/. "$round_dir/"
      KUBECONFIG="$KUBECONFIG" make clean-vcjobs
    ) 2>&1 | tee "$round_dir/benchmark.log"
  done
  delete_current_cluster benchmark
}

case "$MODE" in
  e2e) run_e2e ;;
  benchmark) run_benchmark ;;
  both) run_e2e; run_benchmark ;;
esac

cat > "$OUTPUT_DIR/summary.txt" <<EOF
status=passed
script_version=$SCRIPT_VERSION
mode=$MODE
kubernetes_version=$K8S_VERSION
kind_version=$KIND_VERSION
volcano_repository=$VOLCANO_REPO
volcano_requested_ref=$VOLCANO_REF
volcano_commit=$VOLCANO_COMMIT
e2e_type=$E2E_TYPE
benchmark_scenario=$BENCHMARK_SCENARIO
benchmark_profile=$BENCHMARK_PROFILE
benchmark_rounds=$BENCHMARK_ROUNDS
finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
log "completed successfully; results: $OUTPUT_DIR"
