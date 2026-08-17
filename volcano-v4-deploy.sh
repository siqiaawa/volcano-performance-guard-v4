#!/usr/bin/env bash
# Internal-server entrypoint: load packaged images and exact tools, fetch the
# exact Candidate source, build it with its own Dockerfiles and invoke its own
# E2E or Benchmark code. No Python or project-specific helper is required.
set -Eeuo pipefail

SCRIPT_VERSION="v4.1.1"
DEFAULT_GOPROXY="https://proxy.golang.org,direct"
DEFAULT_GOSUMDB="sum.golang.org"

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
POSIX utilities. Exact Kind, kubectl, Helm, jq, Go and Ginkgo are extracted
from tools.tar.gz into the work directory. Nothing is installed system-wide.
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

for required in bundle.meta images.tar.gz tools.tar.gz SHA256SUMS volcano-v4-deploy.sh; do
  [[ -f "$BUNDLE_ROOT/$required" ]] || die "bundle is missing $required"
done
(cd "$BUNDLE_ROOT" && sha256sum -c SHA256SUMS)

FORMAT=""; K8S_VERSION=""; KIND_VERSION=""; HELM_VERSION=""; JQ_VERSION=""
GO_TOOLCHAIN=""; GINKGO_VERSION=""; VOLCANO_REPO=""
VOLCANO_REF=""; VOLCANO_COMMIT=""; MODE=""; E2E_TYPE=""; BENCHMARK_SCENARIO=""
BENCHMARK_PROFILE=""; BENCHMARK_ROUNDS=""
IMAGE_KEYS=(); IMAGE_PULL_REFS=(); IMAGE_SAVE_REFS=(); IMAGE_IDS=()
TOOL_KEYS=(); TOOL_VERSIONS=(); TOOL_PATHS=(); TOOL_SHA256S=()
while IFS='=' read -r name value; do
  [[ -n "$name" ]] || continue
  case "$name" in
    FORMAT) FORMAT="$value" ;;
    K8S_VERSION) K8S_VERSION="$value" ;;
    KIND_VERSION) KIND_VERSION="$value" ;;
    HELM_VERSION) HELM_VERSION="$value" ;;
    JQ_VERSION) JQ_VERSION="$value" ;;
    GO_TOOLCHAIN) GO_TOOLCHAIN="$value" ;;
    GINKGO_VERSION) GINKGO_VERSION="$value" ;;
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
    TOOL)
      IFS='|' read -r tool_key tool_version tool_path tool_sha <<< "$value"
      TOOL_KEYS+=("$tool_key"); TOOL_VERSIONS+=("$tool_version")
      TOOL_PATHS+=("$tool_path"); TOOL_SHA256S+=("$tool_sha")
      ;;
  esac
done < "$BUNDLE_ROOT/bundle.meta"

[[ "$FORMAT" == "volcano-performance-guard-v4" ]] || die "unsupported bundle format"
valid_semver "$K8S_VERSION" || die "invalid K8S version in bundle"
valid_semver "$KIND_VERSION" || die "invalid Kind version in bundle"
valid_semver "$HELM_VERSION" || die "invalid Helm version in bundle"
[[ "$JQ_VERSION" =~ ^jq-[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid jq version in bundle"
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid Go version in bundle"
[[ "$GINKGO_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "invalid Ginkgo version in bundle"
[[ "$VOLCANO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid Volcano commit in bundle"
valid_mode "$MODE" || die "invalid mode in bundle"
[[ ${#IMAGE_KEYS[@]} -gt 0 ]] || die "bundle has no images"
[[ ${#TOOL_KEYS[@]} -eq 6 ]] || die "bundle must define six packaged tools"
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

TOOLS_DIR="$WORK_DIR/tools"
BIN_DIR="$TOOLS_DIR/bin"
mkdir -p "$BIN_DIR"
log "extracting exact tools from bundle"
safe_extract_bundle "$BUNDLE_ROOT/tools.tar.gz" "$TOOLS_DIR"
for ((index=0; index<${#TOOL_KEYS[@]}; index++)); do
  tool_key="${TOOL_KEYS[$index]}"
  tool_path="${TOOL_PATHS[$index]}"
  expected_sha="${TOOL_SHA256S[$index]}"
  [[ "$tool_key" =~ ^[a-z0-9-]+$ ]] || die "invalid packaged tool key: $tool_key"
  [[ -n "$tool_path" && "$tool_path" != /* && "$tool_path" != ../* && "$tool_path" != *'/../'* ]] || \
    die "unsafe packaged tool path: $tool_path"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "invalid packaged tool checksum: $tool_key"
  [[ -f "$TOOLS_DIR/$tool_path" ]] || die "packaged tool is missing: $tool_path"
  actual_sha="$(sha256sum "$TOOLS_DIR/$tool_path" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || die "packaged tool hash mismatch: $tool_key"
done

for required_tool in kind kubectl helm jq go ginkgo; do
  tool_count=0
  for tool_key in "${TOOL_KEYS[@]}"; do
    [[ "$tool_key" != "$required_tool" ]] || tool_count=$((tool_count+1))
  done
  [[ "$tool_count" -eq 1 ]] || die "bundle must define packaged tool exactly once: $required_tool"
done

for ((index=0; index<${#TOOL_KEYS[@]}; index++)); do
  case "${TOOL_KEYS[$index]}" in
    kind) expected_version="$KIND_VERSION"; expected_path="bin/kind" ;;
    kubectl) expected_version="$K8S_VERSION"; expected_path="bin/kubectl" ;;
    helm) expected_version="$HELM_VERSION"; expected_path="bin/helm" ;;
    jq) expected_version="$JQ_VERSION"; expected_path="bin/jq" ;;
    go) expected_version="$GO_TOOLCHAIN"; expected_path="go/bin/go" ;;
    ginkgo) expected_version="$GINKGO_VERSION"; expected_path="bin/ginkgo" ;;
    *) die "unknown packaged tool: ${TOOL_KEYS[$index]}" ;;
  esac
  [[ "${TOOL_VERSIONS[$index]}" == "$expected_version" ]] || die "packaged tool version metadata mismatch: ${TOOL_KEYS[$index]}"
  [[ "${TOOL_PATHS[$index]}" == "$expected_path" ]] || die "packaged tool path metadata mismatch: ${TOOL_KEYS[$index]}"
done

chmod 0755 "$BIN_DIR/kind" "$BIN_DIR/kubectl" "$BIN_DIR/helm" "$BIN_DIR/jq" \
  "$BIN_DIR/ginkgo" "$TOOLS_DIR/go/bin/go"
export GOROOT="$TOOLS_DIR/go"
export GOTOOLCHAIN=local
export GOPROXY="$GOPROXY_VALUE"
export GOSUMDB="$GOSUMDB_VALUE"
export GOPATH="$WORK_DIR/gopath"
export GOMODCACHE="$WORK_DIR/go-mod-cache"
export GOCACHE="$WORK_DIR/go-build-cache"
export PATH="$GOROOT/bin:$BIN_DIR:$PATH"

kind version | tee "$OUTPUT_DIR/kind-version.log"
kind version | grep -F "$KIND_VERSION" >/dev/null || die "packaged Kind version mismatch"
kubectl version --client -o json > "$OUTPUT_DIR/kubectl-version.json"
[[ "$(jq -r '.clientVersion.gitVersion' "$OUTPUT_DIR/kubectl-version.json")" == "$K8S_VERSION" ]] || die "packaged kubectl version mismatch"
helm version --short | tee "$OUTPUT_DIR/helm-version.log"
helm version --short | grep -F "$HELM_VERSION" >/dev/null || die "packaged Helm version mismatch"
[[ "$(jq --version)" == "$JQ_VERSION" ]] || die "packaged jq version mismatch"
go version | tee "$OUTPUT_DIR/go-version.log"
go version | grep -F " $GO_TOOLCHAIN " >/dev/null || die "packaged Go version mismatch"
ginkgo version | tee "$OUTPUT_DIR/ginkgo-version.log"
ginkgo version | grep -F "${GINKGO_VERSION#v}" >/dev/null || die "packaged Ginkgo version mismatch"
go env GOPROXY GOSUMDB GOTOOLCHAIN GOOS GOARCH > "$OUTPUT_DIR/go-environment.txt"

# Docker's containerd image store reports an OCI index/manifest-list digest as
# .Id, while older Docker releases report the selected image config digest
# after loading the same docker-save archive. Both identities are bound to the
# already verified images.tar.gz. Read the archive's config identity so the
# cross-version check remains strict without assuming one Docker storage model.
IMAGE_ARCHIVE_MANIFEST="$WORK_DIR/image-manifest.json"
gzip -dc "$BUNDLE_ROOT/images.tar.gz" | tar -xOf - manifest.json > "$IMAGE_ARCHIVE_MANIFEST"
[[ -s "$IMAGE_ARCHIVE_MANIFEST" ]] || die "image archive manifest is missing"
jq -e 'type == "array" and length > 0' "$IMAGE_ARCHIVE_MANIFEST" >/dev/null || \
  die "image archive manifest is invalid"

log "loading ordinary Docker images from bundle"
gzip -dc "$BUNDLE_ROOT/images.tar.gz" | docker image load | tee "$OUTPUT_DIR/docker-load.log"
NODE_IMAGE=""
RUNTIME_IMAGES=()
for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
  key="${IMAGE_KEYS[$index]}"; save_ref="${IMAGE_SAVE_REFS[$index]}"; expected_id="${IMAGE_IDS[$index]}"
  [[ "$expected_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid packaged image ID: $save_ref"
  archive_config_path="$(jq -er --arg ref "$save_ref" '
    [.[] | select((.RepoTags // []) | index($ref)) | .Config] | unique |
    if length == 1 then .[0] else error("image tag is absent or ambiguous") end
  ' "$IMAGE_ARCHIVE_MANIFEST")" || die "image archive identity is missing: $save_ref"
  archive_config_hash="${archive_config_path##*/}"
  archive_config_hash="${archive_config_hash%.json}"
  [[ "$archive_config_hash" =~ ^[0-9a-f]{64}$ ]] || die "invalid image archive identity: $save_ref"
  archive_config_id="sha256:$archive_config_hash"

  observed="$(docker image inspect --format '{{.Os}}/{{.Architecture}}|{{.Id}}' "$save_ref" 2>/dev/null)" || \
    die "loaded image is missing: $save_ref"
  [[ "${observed%%|*}" == "linux/amd64" ]] || die "loaded image platform mismatch: $save_ref"
  observed_id="${observed#*|}"
  if [[ "$observed_id" != "$expected_id" && "$observed_id" != "$archive_config_id" ]]; then
    die "loaded image ID mismatch: $save_ref (loaded $observed_id; expected $expected_id or $archive_config_id)"
  fi
  if [[ "$observed_id" == "$archive_config_id" && "$observed_id" != "$expected_id" ]]; then
    log "accepted Docker config identity for $save_ref: $observed_id"
  fi
  if [[ "$key" == "kind-node" ]]; then NODE_IMAGE="$save_ref"; fi
  if [[ "$key" == e2e-* || "$key" == benchmark-* || "$key" == "kwok" || "$key" == extra-* ]]; then
    RUNTIME_IMAGES+=("$save_ref")
  fi
done
[[ -n "$NODE_IMAGE" ]] || die "bundle does not define kind-node"

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

CANDIDATE_GO_DIRECTIVE="$(awk '$1=="go" && NF==2 {print $2; exit}' "$CHECKOUT/go.mod")"
CANDIDATE_GO_TOOLCHAIN="$(awk '$1=="toolchain" && NF==2 {print $2; exit}' "$CHECKOUT/go.mod")"
if [[ -n "$CANDIDATE_GO_TOOLCHAIN" ]]; then
  [[ "$CANDIDATE_GO_TOOLCHAIN" == "$GO_TOOLCHAIN" ]] || die "Candidate Go toolchain changed after packaging"
else
  [[ "$GO_TOOLCHAIN" == "go${CANDIDATE_GO_DIRECTIVE}" || "$GO_TOOLCHAIN" == "go${CANDIDATE_GO_DIRECTIVE}."* ]] || \
    die "packaged Go does not match Candidate go directive"
fi
CANDIDATE_GINKGO_VERSION="$(awk '$1=="github.com/onsi/ginkgo/v2" {print $2; exit} $1=="require" && $2=="github.com/onsi/ginkgo/v2" {print $3; exit}' "$CHECKOUT/go.mod")"
[[ "$CANDIDATE_GINKGO_VERSION" == "$GINKGO_VERSION" ]] || die "Candidate Ginkgo version changed after packaging"

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
