#!/usr/bin/env bash
# Internal entrypoint: verify one dependency bundle, fetch the selected Volcano
# Candidate, build it locally and invoke the Candidate's own E2E/Benchmark code.
set -Eeuo pipefail

SCRIPT_VERSION="v4.2.1"
DEFAULT_GOPROXY="https://proxy.golang.org,direct"
DEFAULT_GOSUMDB="sum.golang.org"

log() { printf '[vpg4-deploy] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
valid_semver() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_mode() { [[ "$1" == e2e || "$1" == benchmark || "$1" == both ]]; }
valid_text() { [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *'|'* ]]; }

usage() {
  cat <<'EOF'
Usage:
  bash volcano-v4-deploy.sh --bundle FILE_OR_DIR [options]
  bash volcano-v4-deploy.sh --bundle-url URL [options]

When run from an extracted bundle containing bundle.meta, --bundle is optional.

Input/output:
  --bundle PATH               Bundle .tar.gz, extracted dir, or .part-000
  --bundle-url URL            Download one unsplit bundle with curl
  --output DIR                Default: ./volcano-v4-results-TIME
  --work-dir DIR              Use a new persistent work directory
  --keep-work-dir             Keep an automatically created work directory
  --keep-cluster              Keep the only/last Kind cluster

Candidate selection:
  --volcano-repo URL          Override the repository recorded in the bundle
  --volcano-ref REF           Override the branch/tag/commit recorded in bundle
  --goproxy VALUE             Inner-server Go module proxy
  --gosumdb VALUE             Inner-server Go checksum database

Run selection (must be covered by the bundle profile):
  --mode e2e|benchmark|both
  --e2e-type TYPE             TYPE or FULL
  --benchmark-scenario NAME   gang, pod, or FULL
  --benchmark-config PATH     Candidate-relative or absolute YAML; one run only
  --benchmark-rounds N        Default: 1
  --pods N                    GENERATED_POD template value; default: 1000
  --scheduler-name NAME       GENERATED_POD value; default: agent-scheduler
  --cluster-prefix NAME       Default: volcano-v4
  --list-capabilities         Verify metadata and print runnable entries only
  -h, --help

The server itself only needs Bash, curl, git, Docker, tar, gzip, sha256sum,
make and basic POSIX tools. Exact Kind, kubectl, Helm, jq and Go come from the
bundle. Ginkgo is installed at the version selected by Candidate go.mod through
the inner Go module channel; nothing is installed system-wide.
EOF
}

BUNDLE_INPUT=""; BUNDLE_URL=""; OUTPUT_DIR=""; WORK_DIR=""
KEEP_WORK_DIR=false; KEEP_CLUSTER=false; LIST_CAPABILITIES=false
MODE_OVERRIDE=""; E2E_TYPE_OVERRIDE=""; BENCHMARK_SCENARIO_OVERRIDE=""
BENCHMARK_CONFIG_OVERRIDE=""; BENCHMARK_ROUNDS=1; PODS=1000
SCHEDULER_NAME="agent-scheduler"; CLUSTER_PREFIX="volcano-v4"
VOLCANO_REPO_OVERRIDE=""; VOLCANO_REF_OVERRIDE=""
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
    --volcano-repo) VOLCANO_REPO_OVERRIDE="${2:-}"; shift 2 ;;
    --volcano-ref) VOLCANO_REF_OVERRIDE="${2:-}"; shift 2 ;;
    --mode) MODE_OVERRIDE="${2:-}"; shift 2 ;;
    --e2e-type) E2E_TYPE_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-scenario) BENCHMARK_SCENARIO_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-config|--benchmark-profile) BENCHMARK_CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-rounds) BENCHMARK_ROUNDS="${2:-}"; shift 2 ;;
    --pods) PODS="${2:-}"; shift 2 ;;
    --scheduler-name) SCHEDULER_NAME="${2:-}"; shift 2 ;;
    --cluster-prefix) CLUSTER_PREFIX="${2:-}"; shift 2 ;;
    --goproxy) GOPROXY_VALUE="${2:-}"; shift 2 ;;
    --gosumdb) GOSUMDB_VALUE="${2:-}"; shift 2 ;;
    --list-capabilities) LIST_CAPABILITIES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

[[ -z "$BUNDLE_INPUT" || -z "$BUNDLE_URL" ]] || die "use only one of --bundle and --bundle-url"
[[ "$CLUSTER_PREFIX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "invalid --cluster-prefix"
[[ "$BENCHMARK_ROUNDS" =~ ^[1-9][0-9]*$ ]] || die "--benchmark-rounds must be positive"
[[ "$PODS" =~ ^[1-9][0-9]*$ ]] || die "--pods must be positive"
[[ "$SCHEDULER_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "invalid --scheduler-name"
valid_text "$GOPROXY_VALUE" || die "invalid --goproxy"
valid_text "$GOSUMDB_VALUE" || die "invalid --gosumdb"
[[ -z "$MODE_OVERRIDE" ]] || valid_mode "$MODE_OVERRIDE" || die "invalid --mode"

for command in curl git tar gzip sha256sum awk sed grep sort mktemp; do need "$command"; done
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "deployment requires Linux x86_64"

if [[ -z "$OUTPUT_DIR" ]]; then OUTPUT_DIR="./volcano-v4-results-$(date -u +%Y%m%d-%H%M%S)"; fi
[[ ! -e "$OUTPUT_DIR" ]] || die "output already exists: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

AUTO_WORK=false
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d /tmp/volcano-v4-deploy.XXXXXX)"; AUTO_WORK=true
else
  [[ ! -e "$WORK_DIR" ]] || die "work directory already exists: $WORK_DIR"
  mkdir -p "$WORK_DIR"; WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
fi
CURRENT_CLUSTER=""; CLUSTER_CREATED=false
cleanup() {
  status=$?
  if [[ "$CLUSTER_CREATED" == true && "$KEEP_CLUSTER" != true && -n "$CURRENT_CLUSTER" ]] && command -v kind >/dev/null 2>&1; then
    log "deleting project cluster after interruption: $CURRENT_CLUSTER"
    kind delete cluster --name "$CURRENT_CLUSTER" >"$OUTPUT_DIR/kind-delete-trap.log" 2>&1 || true
  fi
  if [[ "$AUTO_WORK" == true && "$KEEP_WORK_DIR" != true ]]; then rm -rf -- "$WORK_DIR"
  else log "kept work directory: $WORK_DIR"; fi
  if [[ "$status" -ne 0 && ! -f "$OUTPUT_DIR/summary.txt" ]]; then
    printf 'status=failed\nscript_version=%s\nprofile=%s\nmode=%s\nfinished_at=%s\n' \
      "$SCRIPT_VERSION" "${PROFILE:-unknown}" "${MODE:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$OUTPUT_DIR/summary.txt"
  fi
  exit "$status"
}
trap cleanup EXIT

safe_extract() {
  local archive="$1" destination="$2" entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" != /* && "$entry" != ../* && "$entry" != *'/../'* ]] || die "unsafe archive path: $entry"
  done < <(tar -tzf "$archive")
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination" --no-same-owner --no-same-permissions
}

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
if [[ -d "$BUNDLE_INPUT" ]]; then
  BUNDLE_ROOT="$(cd "$BUNDLE_INPUT" && pwd -P)"
else
  [[ -f "$BUNDLE_INPUT" ]] || die "bundle does not exist: $BUNDLE_INPUT"
  if [[ "$BUNDLE_INPUT" == *.part-[0-9][0-9][0-9] ]]; then
    prefix="${BUNDLE_INPUT%.part-*}"; part_dir="$(cd "$(dirname "$BUNDLE_INPUT")" && pwd -P)"
    [[ -f "${prefix}.parts.sha256" ]] || die "split checksum manifest is missing"
    (cd "$part_dir" && sha256sum -c "$(basename "${prefix}.parts.sha256")")
    combined="$WORK_DIR/reassembled-bundle.tar.gz"
    cat "${prefix}.part-"[0-9][0-9][0-9] > "$combined"; BUNDLE_INPUT="$combined"
  elif [[ -f "${BUNDLE_INPUT}.sha256" ]]; then
    (cd "$(dirname "$BUNDLE_INPUT")" && sha256sum -c "$(basename "${BUNDLE_INPUT}.sha256")")
  fi
  safe_extract "$BUNDLE_INPUT" "$WORK_DIR/extracted"
  shopt -s nullglob; roots=("$WORK_DIR/extracted"/*); shopt -u nullglob
  [[ ${#roots[@]} -eq 1 && -d "${roots[0]}" ]] || die "bundle must contain exactly one top-level directory"
  BUNDLE_ROOT="${roots[0]}"
fi

for required in bundle.meta images.tar.gz tools.tar.gz resources.tar.gz SHA256SUMS volcano-v4-deploy.sh; do
  [[ -f "$BUNDLE_ROOT/$required" ]] || die "bundle is missing $required"
done
(cd "$BUNDLE_ROOT" && sha256sum -c SHA256SUMS)

FORMAT=""; BUNDLE_SCRIPT_VERSION=""; PLATFORM=""; PROFILE=""; PACKAGED_MODE=""; DEFAULT_RUN=""
K8S_VERSION=""; KIND_VERSION=""; HELM_VERSION=""; JQ_VERSION=""; KWOK_VERSION=""; GO_TOOLCHAIN=""
VOLCANO_REPO=""; BUNDLED_VOLCANO_REF=""; BUNDLED_VOLCANO_COMMIT=""
IMAGE_KEYS=(); IMAGE_PULL_REFS=(); IMAGE_SAVE_REFS=(); IMAGE_IDS=()
TOOL_KEYS=(); TOOL_VERSIONS=(); TOOL_PATHS=(); TOOL_SHA256S=()
RESOURCE_KEYS=(); RESOURCE_PATHS=(); RESOURCE_SHA256S=()
E2E_CAPS=(); BENCHMARK_CAP_SCENARIOS=(); BENCHMARK_CAP_CONFIGS=()
while IFS='=' read -r name value; do
  [[ -n "$name" ]] || continue
  case "$name" in
    FORMAT) FORMAT="$value" ;;
    SCRIPT_VERSION) BUNDLE_SCRIPT_VERSION="$value" ;;
    CREATED_AT) ;;
    PLATFORM) PLATFORM="$value" ;;
    PROFILE) PROFILE="$value" ;;
    MODE) PACKAGED_MODE="$value" ;;
    DEFAULT_RUN) DEFAULT_RUN="$value" ;;
    K8S_VERSION) K8S_VERSION="$value" ;;
    KIND_VERSION) KIND_VERSION="$value" ;;
    HELM_VERSION) HELM_VERSION="$value" ;;
    JQ_VERSION) JQ_VERSION="$value" ;;
    KWOK_VERSION) KWOK_VERSION="$value" ;;
    GO_TOOLCHAIN) GO_TOOLCHAIN="$value" ;;
    VOLCANO_REPO) VOLCANO_REPO="$value" ;;
    VOLCANO_REF) BUNDLED_VOLCANO_REF="$value" ;;
    VOLCANO_COMMIT) BUNDLED_VOLCANO_COMMIT="$value" ;;
    IMAGE)
      IFS='|' read -r a b c d e extra <<< "$value"; [[ -z "$extra" ]] || die "invalid IMAGE metadata"
      IMAGE_KEYS+=("$a"); IMAGE_PULL_REFS+=("$b"); IMAGE_SAVE_REFS+=("$c"); IMAGE_IDS+=("$d")
      ;;
    TOOL)
      IFS='|' read -r a b c d extra <<< "$value"; [[ -z "$extra" ]] || die "invalid TOOL metadata"
      TOOL_KEYS+=("$a"); TOOL_VERSIONS+=("$b"); TOOL_PATHS+=("$c"); TOOL_SHA256S+=("$d")
      ;;
    RESOURCE)
      IFS='|' read -r a b c extra <<< "$value"; [[ -z "$extra" ]] || die "invalid RESOURCE metadata"
      RESOURCE_KEYS+=("$a"); RESOURCE_PATHS+=("$b"); RESOURCE_SHA256S+=("$c")
      ;;
    E2E_CAP) E2E_CAPS+=("$value") ;;
    BENCHMARK_CAP)
      IFS='|' read -r a b extra <<< "$value"; [[ -z "$extra" ]] || die "invalid BENCHMARK_CAP metadata"
      BENCHMARK_CAP_SCENARIOS+=("$a"); BENCHMARK_CAP_CONFIGS+=("$b")
      ;;
    *) die "unknown metadata key: $name" ;;
  esac
done < "$BUNDLE_ROOT/bundle.meta"

[[ "$FORMAT" == volcano-performance-guard-v4 ]] || die "unsupported bundle format"
[[ "$BUNDLE_SCRIPT_VERSION" == "$SCRIPT_VERSION" ]] || die "bundle/script version mismatch"
[[ "$PLATFORM" == linux/amd64 ]] || die "unsupported bundle platform: $PLATFORM"
valid_text "$PROFILE" || die "invalid profile metadata"
valid_mode "$PACKAGED_MODE" || die "invalid mode metadata"
valid_semver "$K8S_VERSION" || die "invalid Kubernetes version metadata"
valid_semver "$KIND_VERSION" || die "invalid Kind version metadata"
valid_semver "$HELM_VERSION" || die "invalid Helm version metadata"
valid_semver "$KWOK_VERSION" || die "invalid KWOK version metadata"
[[ "$JQ_VERSION" =~ ^jq-[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid jq version metadata"
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid Go version metadata"
[[ "$BUNDLED_VOLCANO_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid Candidate commit metadata"
[[ ${#IMAGE_KEYS[@]} -gt 0 ]] || die "bundle contains no images"
[[ ${#TOOL_KEYS[@]} -eq 5 ]] || die "bundle must contain exactly five tools"

MODE="${MODE_OVERRIDE:-$PACKAGED_MODE}"
if [[ "$PACKAGED_MODE" != both && "$MODE" != "$PACKAGED_MODE" ]]; then die "requested mode $MODE is not covered by profile $PROFILE"; fi
[[ "$MODE" == benchmark || ${#E2E_CAPS[@]} -gt 0 ]] || die "bundle has no E2E capability"
[[ "$MODE" == e2e || ${#BENCHMARK_CAP_SCENARIOS[@]} -gt 0 ]] || die "bundle has no Benchmark capability"

printf 'profile=%s\nmode=%s\ndefault_run=%s\n' "$PROFILE" "$PACKAGED_MODE" "$DEFAULT_RUN"
if [[ ${#E2E_CAPS[@]} -gt 0 ]]; then
  for value in "${E2E_CAPS[@]}"; do printf 'e2e=%s\n' "$value"; done
fi
for ((index=0; index<${#BENCHMARK_CAP_SCENARIOS[@]}; index++)); do
  printf 'benchmark=%s|%s\n' "${BENCHMARK_CAP_SCENARIOS[$index]}" "${BENCHMARK_CAP_CONFIGS[$index]}"
done
if [[ "$LIST_CAPABILITIES" == true ]]; then
  cat > "$OUTPUT_DIR/summary.txt" <<EOF
status=capabilities-listed
script_version=$SCRIPT_VERSION
profile=$PROFILE
packaged_mode=$PACKAGED_MODE
EOF
  log "capabilities verified; no Docker operation was performed"
  exit 0
fi

need docker; need make; need tee
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

TOOLS_DIR="$WORK_DIR/tools"; BIN_DIR="$TOOLS_DIR/bin"; RESOURCES_DIR="$WORK_DIR/resources"
safe_extract "$BUNDLE_ROOT/tools.tar.gz" "$TOOLS_DIR"
safe_extract "$BUNDLE_ROOT/resources.tar.gz" "$RESOURCES_DIR"
for ((index=0; index<${#TOOL_KEYS[@]}; index++)); do
  key="${TOOL_KEYS[$index]}"; path="${TOOL_PATHS[$index]}"; expected="${TOOL_SHA256S[$index]}"
  [[ "$key" =~ ^[a-z0-9-]+$ ]] || die "invalid tool key: $key"
  [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != *'/../'* ]] || die "unsafe tool path: $path"
  [[ "$expected" =~ ^[0-9a-f]{64}$ && -f "$TOOLS_DIR/$path" ]] || die "invalid packaged tool: $key"
  [[ "$(sha256sum "$TOOLS_DIR/$path"|awk '{print $1}')" == "$expected" ]] || die "tool checksum mismatch: $key"
done
for required in kind kubectl helm jq go; do
  count=0; for key in "${TOOL_KEYS[@]}"; do [[ "$key" != "$required" ]] || count=$((count+1)); done
  [[ "$count" -eq 1 ]] || die "tool must be defined exactly once: $required"
done
for ((index=0; index<${#RESOURCE_KEYS[@]}; index++)); do
  key="${RESOURCE_KEYS[$index]}"; path="${RESOURCE_PATHS[$index]}"; expected="${RESOURCE_SHA256S[$index]}"
  [[ "$key" =~ ^[a-z0-9-]+$ ]] || die "invalid resource key: $key"
  [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != *'/../'* ]] || die "unsafe resource path: $path"
  [[ "$expected" =~ ^[0-9a-f]{64}$ && -f "$RESOURCES_DIR/$path" ]] || die "invalid resource: $key"
  [[ "$(sha256sum "$RESOURCES_DIR/$path"|awk '{print $1}')" == "$expected" ]] || die "resource checksum mismatch: $key"
done

chmod 0755 "$BIN_DIR/kind" "$BIN_DIR/kubectl" "$BIN_DIR/helm" "$BIN_DIR/jq" "$TOOLS_DIR/go/bin/go"
export GOROOT="$TOOLS_DIR/go" GOTOOLCHAIN=local GOPATH="$WORK_DIR/gopath"
export GOMODCACHE="$WORK_DIR/go-mod-cache" GOCACHE="$WORK_DIR/go-build-cache"
export GOPROXY="$GOPROXY_VALUE" GOSUMDB="$GOSUMDB_VALUE"
export PATH="$GOROOT/bin:$GOPATH/bin:$BIN_DIR:$PATH"

kind version | tee "$OUTPUT_DIR/kind-version.log"
kind version | grep -F "$KIND_VERSION" >/dev/null || die "Kind version mismatch"
kubectl version --client -o json > "$OUTPUT_DIR/kubectl-version.json"
[[ "$(jq -r '.clientVersion.gitVersion' "$OUTPUT_DIR/kubectl-version.json")" == "$K8S_VERSION" ]] || die "kubectl version mismatch"
helm version --short | tee "$OUTPUT_DIR/helm-version.log"
helm version --short | grep -F "$HELM_VERSION" >/dev/null || die "Helm version mismatch"
[[ "$(jq --version)" == "$JQ_VERSION" ]] || die "jq version mismatch"
go version | tee "$OUTPUT_DIR/go-version.log"
go version | grep -F " $GO_TOOLCHAIN " >/dev/null || die "Go version mismatch"
go env GOPROXY GOSUMDB GOTOOLCHAIN GOOS GOARCH > "$OUTPUT_DIR/go-environment.txt"

# Docker 29 may report the OCI descriptor ID while older stores report the
# docker-save config ID. Both are accepted only after images.tar.gz is hashed.
IMAGE_ARCHIVE_MANIFEST="$WORK_DIR/image-manifest.json"
gzip -dc "$BUNDLE_ROOT/images.tar.gz" | tar -xOf - manifest.json > "$IMAGE_ARCHIVE_MANIFEST"
jq -e 'type=="array" and length>0' "$IMAGE_ARCHIVE_MANIFEST" >/dev/null || die "invalid image archive manifest"
gzip -dc "$BUNDLE_ROOT/images.tar.gz" | docker image load | tee "$OUTPUT_DIR/docker-load.log"
NODE_IMAGE=""
for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
  key="${IMAGE_KEYS[$index]}"; save_ref="${IMAGE_SAVE_REFS[$index]}"; expected_id="${IMAGE_IDS[$index]}"
  [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ && "$expected_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid image metadata"
  config_path="$(jq -er --arg ref "$save_ref" '[.[]|select((.RepoTags//[])|index($ref))|.Config]|unique|if length==1 then .[0] else error("missing") end' "$IMAGE_ARCHIVE_MANIFEST")" || die "archive image identity missing: $save_ref"
  config_hash="${config_path##*/}"; config_hash="${config_hash%.json}"; config_id="sha256:$config_hash"
  [[ "$config_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid archive image identity: $save_ref"
  observed="$(docker image inspect --format '{{.Os}}/{{.Architecture}}|{{.Id}}' "$save_ref")"
  [[ "${observed%%|*}" == linux/amd64 ]] || die "image platform mismatch: $save_ref"
  observed_id="${observed#*|}"
  [[ "$observed_id" == "$expected_id" || "$observed_id" == "$config_id" ]] || die "loaded image ID mismatch: $save_ref"
  [[ "$key" != kind-node ]] || NODE_IMAGE="$save_ref"
done
[[ -n "$NODE_IMAGE" ]] || die "bundle does not contain kind-node"

has_image_key() { local wanted="$1" x; for x in "${IMAGE_KEYS[@]}"; do [[ "$x" == "$wanted" ]] && return 0; done; return 1; }
resource_for_key() { local wanted="$1" i; for ((i=0;i<${#RESOURCE_KEYS[@]};i++)); do [[ "${RESOURCE_KEYS[$i]}" != "$wanted" ]] || { printf '%s\n' "$RESOURCES_DIR/${RESOURCE_PATHS[$i]}"; return; }; done; return 1; }

VOLCANO_REPO="${VOLCANO_REPO_OVERRIDE:-$VOLCANO_REPO}"
REQUESTED_VOLCANO_REF="${VOLCANO_REF_OVERRIDE:-$BUNDLED_VOLCANO_COMMIT}"
valid_text "$VOLCANO_REPO" || die "invalid selected Volcano repository"
valid_text "$REQUESTED_VOLCANO_REF" || die "invalid selected Volcano ref"
CHECKOUT="$WORK_DIR/volcano"
git init "$CHECKOUT" >/dev/null; git -C "$CHECKOUT" remote add origin "$VOLCANO_REPO"
log "fetching Volcano Candidate: $REQUESTED_VOLCANO_REF"
git -C "$CHECKOUT" fetch --depth 1 origin "$REQUESTED_VOLCANO_REF"
git -C "$CHECKOUT" checkout --detach FETCH_HEAD
CANDIDATE_COMMIT="$(git -C "$CHECKOUT" rev-parse HEAD)"
[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve selected Candidate"
if [[ -f "$CHECKOUT/.gitmodules" ]]; then git -C "$CHECKOUT" submodule update --init --recursive --depth 1; fi
git -C "$CHECKOUT" status --short > "$OUTPUT_DIR/candidate-status-before-environment-patch.txt"
printf '%s\n' "$CANDIDATE_COMMIT" > "$OUTPUT_DIR/candidate-commit.txt"

CANDIDATE_GO="$(awk '$1=="toolchain"&&NF==2 {print $2;exit}' "$CHECKOUT/go.mod")"
[[ -n "$CANDIDATE_GO" ]] || CANDIDATE_GO="go$(awk '$1=="go"&&NF==2 {print $2;exit}' "$CHECKOUT/go.mod")"
[[ "$CANDIDATE_GO" == "$GO_TOOLCHAIN" ]] || die "Candidate needs $CANDIDATE_GO but bundle contains $GO_TOOLCHAIN; repack for this Candidate"
if [[ "$MODE" != benchmark ]]; then
  GINKGO_VERSION="$(awk '$1=="github.com/onsi/ginkgo/v2" {print $2;exit} $1=="require"&&$2=="github.com/onsi/ginkgo/v2" {print $3;exit}' "$CHECKOUT/go.mod")"
  [[ "$GINKGO_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "cannot resolve Candidate Ginkgo version"
  log "installing Candidate-selected Ginkgo $GINKGO_VERSION through GOPROXY"
  go install "github.com/onsi/ginkgo/v2/ginkgo@$GINKGO_VERSION"
  ginkgo version | tee "$OUTPUT_DIR/ginkgo-version.log"
fi

E2E_SELECTION="${E2E_TYPE_OVERRIDE:-$DEFAULT_RUN}"
BENCHMARK_SELECTION="${BENCHMARK_SCENARIO_OVERRIDE:-$DEFAULT_RUN}"
if [[ "$MODE" == both ]]; then
  [[ -n "$E2E_TYPE_OVERRIDE" ]] || E2E_SELECTION=FULL
  [[ -n "$BENCHMARK_SCENARIO_OVERRIDE" ]] || BENCHMARK_SELECTION=FULL
fi
if [[ "$MODE" != benchmark ]]; then
  if [[ "$E2E_SELECTION" == FULL ]]; then E2E_RUNS=("${E2E_CAPS[@]}")
  else
    found=false; for value in "${E2E_CAPS[@]}"; do [[ "$value" != "$E2E_SELECTION" ]] || found=true; done
    [[ "$found" == true ]] || die "E2E type $E2E_SELECTION is not covered by profile $PROFILE"
    E2E_RUNS=("$E2E_SELECTION")
  fi
else E2E_RUNS=(); fi

BENCHMARK_RUN_SCENARIOS=(); BENCHMARK_RUN_CONFIGS=()
if [[ "$MODE" != e2e ]]; then
  if [[ "$BENCHMARK_SELECTION" == FULL ]]; then
    [[ -z "$BENCHMARK_CONFIG_OVERRIDE" ]] || die "--benchmark-config cannot be combined with FULL"
    BENCHMARK_RUN_SCENARIOS=("${BENCHMARK_CAP_SCENARIOS[@]}"); BENCHMARK_RUN_CONFIGS=("${BENCHMARK_CAP_CONFIGS[@]}")
  else
    for ((index=0; index<${#BENCHMARK_CAP_SCENARIOS[@]}; index++)); do
      if [[ "${BENCHMARK_CAP_SCENARIOS[$index]}" == "$BENCHMARK_SELECTION" ]]; then
        BENCHMARK_RUN_SCENARIOS+=("$BENCHMARK_SELECTION"); BENCHMARK_RUN_CONFIGS+=("${BENCHMARK_CAP_CONFIGS[$index]}"); break
      fi
    done
    [[ ${#BENCHMARK_RUN_SCENARIOS[@]} -eq 1 ]] || die "Benchmark scenario $BENCHMARK_SELECTION is not covered by profile $PROFILE"
    [[ -z "$BENCHMARK_CONFIG_OVERRIDE" ]] || BENCHMARK_RUN_CONFIGS[0]="$BENCHMARK_CONFIG_OVERRIDE"
  fi
else BENCHMARK_RUN_SCENARIOS=(); fi
[[ "$KEEP_CLUSTER" != true || $(( ${#E2E_RUNS[@]} + ${#BENCHMARK_RUN_SCENARIOS[@]} )) -eq 1 ]] || die "--keep-cluster requires exactly one run"

# Local image reuse requires the Docker buildx driver; docker-container cannot
# see the imported bases without a registry.
docker buildx inspect default >/dev/null 2>&1 || die "Docker default buildx builder is unavailable"
driver="$(docker buildx inspect default | awk -F': ' '/^Driver:/ {print $2;exit}' | tr -d '[:space:]')"
[[ "$driver" == docker ]] || die "offline build requires the default Docker buildx driver, got ${driver:-unknown}"
docker buildx use default; export BUILDX_BUILDER=default

BUILD_AGENT=false
if [[ ${#E2E_RUNS[@]} -gt 0 ]]; then
  for value in "${E2E_RUNS[@]}"; do [[ "$value" != AGENTSCHEDULER_* ]] || BUILD_AGENT=true; done
fi
if [[ ${#BENCHMARK_RUN_SCENARIOS[@]} -gt 0 ]]; then
  for value in "${BENCHMARK_RUN_SCENARIOS[@]}"; do [[ "$value" != pod ]] || BUILD_AGENT=true; done
fi
DOCKERFILES=(scheduler controller-manager webhook-manager)
[[ "$BUILD_AGENT" != true ]] || DOCKERFILES+=(agent-scheduler)
if [[ ${#BENCHMARK_RUN_SCENARIOS[@]} -gt 0 ]] && has_image_key prometheus; then DOCKERFILES+=(benchmark-audit-exporter); fi
for name in "${DOCKERFILES[@]}"; do
  if [[ "$name" == benchmark-audit-exporter ]]; then path="$CHECKOUT/benchmark/manifests/audit-exporter/Dockerfile"
  else path="$CHECKOUT/installer/dockerfile/$name/Dockerfile"; fi
  [[ -f "$path" ]] || die "Candidate Dockerfile missing: $path"
  while IFS= read -r base; do
    [[ "$base" != *'${'* ]] || die "unresolved Candidate base in $path: $base"
    docker image inspect "${base%@*}" >/dev/null 2>&1 || die "Candidate base is not bundled: $base; repack for this Candidate"
  # Keep the inner preflight identical to the packager for CRLF Dockerfiles.
  done < <(awk 'toupper($1)=="FROM" {for(i=2;i<=NF;i++) if($i!~/^--/){gsub(/\r/,"",$i);print $i;break}}' "$path" | sort -u)
done

BUILD_TARGETS=(vc-scheduler-image vc-controller-manager-image vc-webhook-manager-image)
[[ "$BUILD_AGENT" != true ]] || BUILD_TARGETS+=(vc-agent-scheduler-image)
log "building Candidate images at $CANDIDATE_COMMIT"
(
  cd "$CHECKOUT"
  make "${BUILD_TARGETS[@]}" "TAG=$CANDIDATE_COMMIT" IMAGE_PREFIX=volcanosh FORCE_REBUILD=true \
    BUILDX_OUTPUT_TYPE=docker DOCKER_PLATFORMS=linux/amd64
) 2>&1 | tee "$OUTPUT_DIR/candidate-build.log"
CANDIDATE_IMAGES=("volcanosh/vc-scheduler:$CANDIDATE_COMMIT" "volcanosh/vc-controller-manager:$CANDIDATE_COMMIT" "volcanosh/vc-webhook-manager:$CANDIDATE_COMMIT")
[[ "$BUILD_AGENT" != true ]] || CANDIDATE_IMAGES+=("volcanosh/vc-agent-scheduler:$CANDIDATE_COMMIT")
for image in "${CANDIDATE_IMAGES[@]}"; do
  [[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" == linux/amd64 ]] || die "Candidate image platform mismatch: $image"
done

cluster_name() { local purpose="$1" index="$2" name="${CLUSTER_PREFIX}-${CANDIDATE_COMMIT:0:8}-${purpose}-${index}"; name="${name:0:63}"; printf '%s\n' "${name%-}"; }
cluster_exists() { kind get clusters 2>/dev/null | grep -Fxq "$1"; }
delete_cluster() {
  local purpose="$1"
  if [[ "$KEEP_CLUSTER" == true ]]; then log "keeping cluster: $CURRENT_CLUSTER"; return; fi
  if cluster_exists "$CURRENT_CLUSTER"; then kind delete cluster --name "$CURRENT_CLUSTER" 2>&1 | tee "$OUTPUT_DIR/kind-delete-${purpose}.log"; fi
  CLUSTER_CREATED=false; CURRENT_CLUSTER=""
}
load_image_list() {
  local name="$1" file="$2" image
  while IFS= read -r image; do [[ -z "$image" ]] || kind load docker-image "$image" --name "$name"; done < "$file"
}
write_runtime_images() {
  local purpose="$1" output="$2" i key ref
  : > "$output"
  for ((i=0;i<${#IMAGE_KEYS[@]};i++)); do
    key="${IMAGE_KEYS[$i]}"; ref="${IMAGE_SAVE_REFS[$i]}"
    case "$key" in
      kind-node|candidate-base-*) ;;
      extra-*) printf '%s\n' "$ref" >> "$output" ;;
      busybox-default|busybox-1-24|nginx-default|nginx-latest|k8s-e2e-nginx|kwok)
        [[ "$purpose" == e2e* ]] && printf '%s\n' "$ref" >> "$output" ;;
      mpi|tensorflow|pytorch|ray)
        [[ "$purpose" == e2e-ALL || "$purpose" == e2e-JOBSEQ ]] && printf '%s\n' "$ref" >> "$output" ;;
      dra-hostpath)
        [[ "$purpose" == e2e-ALL || "$purpose" == e2e-DRA ]] && printf '%s\n' "$ref" >> "$output" ;;
      benchmark-busybox)
        [[ "$purpose" == benchmark* ]] && printf '%s\n' "$ref" >> "$output" ;;
      prometheus|grafana|kube-state-metrics)
        [[ "$purpose" == benchmark* ]] && printf '%s\n' "$ref" >> "$output" ;;
    esac
  done
  sort -u -o "$output" "$output"
}

patch_e2e_environment() {
  local install="$CHECKOUT/hack/lib/install.sh" runner="$CHECKOUT/hack/run-e2e-kind.sh" tmp="$WORK_DIR/patch.tmp"
  [[ -f "$install" && -f "$runner" ]] || die "Candidate E2E entrypoints are missing"
  awk '
    BEGIN{inside=0; replaced=0}
    /^[[:space:]]*(function[[:space:]]+)?install-kwok-with-helm([[:space:]]*\(\))?[[:space:]]*\{/ {
      print "install-kwok-with-helm() {"
      print "  kubectl apply -f \"${VPG_KWOK_MANIFEST:?}\""
      print "  kubectl apply -f \"${VPG_KWOK_STAGE:?}\""
      print "  kubectl wait --for=condition=Available deployment/kwok-controller -n kube-system --timeout=120s"
      print "  kubectl delete stage pod-complete --ignore-not-found >/dev/null 2>&1 || true"
      print "}"
      inside=1; replaced++; next
    }
    inside && /^}/ {inside=0; next}
    inside {next}
    {print}
    END{if(replaced!=1) exit 42}
  ' "$install" > "$tmp" || die "cannot adapt Candidate KWOK installer"
  mv "$tmp" "$install"
  awk '
    BEGIN{pending=0; inserted=0}
    {
      print
      if($0 ~ /^[[:space:]]*kind[[:space:]]+create[[:space:]]+cluster/) pending=1
      if(pending && $0 !~ /\\[[:space:]]*$/) {
        print "  if [[ -n \"${VPG_RUNTIME_IMAGE_FILE:-}\" ]]; then"
        print "    while IFS= read -r vpg_image; do"
        print "      [[ -z \"${vpg_image}\" ]] || kind load docker-image \"${vpg_image}\" --name \"${CLUSTER_NAME}\""
        print "    done < \"${VPG_RUNTIME_IMAGE_FILE}\""
        print "  fi"
        pending=0; inserted++
      }
    }
    END{if(inserted!=1) exit 43}
  ' "$install" > "$tmp" || die "cannot add offline image loading to Candidate Kind helper"
  mv "$tmp" "$install"
  git -C "$CHECKOUT" diff -- hack/lib/install.sh hack/run-e2e-kind.sh > "$OUTPUT_DIR/candidate-environment.patch"
  [[ -s "$OUTPUT_DIR/candidate-environment.patch" ]] || die "Candidate environment patch is empty"
}

if [[ ${#E2E_RUNS[@]} -gt 0 ]]; then patch_e2e_environment; fi

run_e2e_one() {
  local type="$1" number="$2" name runtime artifacts cleanup_value=1
  name="$(cluster_name "e2e-${type,,}" "$number")"; runtime="$WORK_DIR/runtime-e2e-$number.txt"
  artifacts="$OUTPUT_DIR/e2e-$number-$type"; mkdir -p "$artifacts"
  write_runtime_images "e2e-$type" "$runtime"
  cluster_exists "$name" && die "project cluster already exists: $name"
  CURRENT_CLUSTER="$name"; CLUSTER_CREATED=true
  [[ "$KEEP_CLUSTER" != true ]] || cleanup_value=0
  log "running Candidate E2E $type in $name"
  (
    cd "$CHECKOUT"
    E2E_TYPE="$type" CLUSTER_NAME="$name" CLEANUP_CLUSTER="$cleanup_value" \
      KIND_OPT="--image $NODE_IMAGE --config $CHECKOUT/hack/e2e-kind-config.yaml" \
      IMAGE_PREFIX=volcanosh TAG="$CANDIDATE_COMMIT" OS=linux ARTIFACTS_PATH="$artifacts" \
      VPG_RUNTIME_IMAGE_FILE="$runtime" VPG_KWOK_MANIFEST="$(resource_for_key kwok-manifest)" \
      VPG_KWOK_STAGE="$(resource_for_key kwok-stage)" bash hack/run-e2e-kind.sh
  ) 2>&1 | tee "$artifacts/run.log"
  if [[ "$KEEP_CLUSTER" != true ]]; then
    cluster_exists "$name" && kind delete cluster --name "$name" >/dev/null 2>&1 || true
    CLUSTER_CREATED=false; CURRENT_CLUSTER=""
  fi
}

create_benchmark_cluster() {
  local name="$1" number="$2" config="$WORK_DIR/kind-benchmark-$number.yaml" runtime="$WORK_DIR/runtime-benchmark-$number.txt"
  [[ -f "$CHECKOUT/benchmark/config/kind-config.yaml" ]] || die "Candidate Benchmark Kind config is missing"
  sed "s|__VOLCANO_ROOT__|$CHECKOUT|g" "$CHECKOUT/benchmark/config/kind-config.yaml" > "$config"
  cluster_exists "$name" && die "project cluster already exists: $name"
  CURRENT_CLUSTER="$name"; CLUSTER_CREATED=true
  kind create cluster --name "$name" --image "$NODE_IMAGE" --config "$config" --wait 300s 2>&1 | tee "$OUTPUT_DIR/kind-create-benchmark-$number.log"
  KUBECONFIG="$OUTPUT_DIR/kubeconfig-benchmark-$number"; export KUBECONFIG
  kind get kubeconfig --name "$name" > "$KUBECONFIG"; chmod 0600 "$KUBECONFIG"
  observed="$(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
  [[ "$observed" == "$K8S_VERSION" ]] || die "Kubernetes version mismatch: expected $K8S_VERSION, got $observed"
  write_runtime_images benchmark "$runtime"
  for image in "${CANDIDATE_IMAGES[@]}"; do printf '%s\n' "$image" >> "$runtime"; done
  sort -u -o "$runtime" "$runtime"; load_image_list "$name" "$runtime" 2>&1 | tee "$OUTPUT_DIR/kind-load-benchmark-$number.log"
  kubectl apply -f "$(resource_for_key kwok-manifest)"
  kubectl apply -f "$(resource_for_key kwok-stage)"
  kubectl wait --for=condition=Available deployment/kwok-controller -n kube-system --timeout=120s
}

install_candidate() {
  local number="$1"
  helm upgrade --install volcano "$CHECKOUT/installer/helm/chart/volcano" --namespace volcano-system \
    --create-namespace --set basic.image_pull_policy=IfNotPresent \
    --set "basic.image_tag_version=$CANDIDATE_COMMIT" \
    --set basic.scheduler_config_file=volcano-scheduler-configmap \
    --set "custom.agent_scheduler_enable=$BUILD_AGENT" \
    --set custom.scheduler_kube_api_qps=5000 --set custom.scheduler_kube_api_burst=10000 \
    --set custom.controller_kube_api_qps=5000 --set custom.controller_kube_api_burst=10000 \
    --wait --timeout 300s 2>&1 | tee "$OUTPUT_DIR/helm-install-benchmark-$number.log"
}

prepare_monitoring() {
  local name="$1" number="$2" manifest="$CHECKOUT/installer/volcano-monitoring.yaml"
  [[ -f "$manifest" ]] || die "Candidate monitoring manifest is missing"
  docker build -f "$CHECKOUT/benchmark/manifests/audit-exporter/Dockerfile" \
    -t volcanosh/kube-apiserver-audit-exporter:dev "$CHECKOUT" \
    2>&1 | tee "$OUTPUT_DIR/audit-exporter-build-$number.log"
  kind load docker-image volcanosh/kube-apiserver-audit-exporter:dev --name "$name"
  sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' "$manifest"
  sed -i -E '/^[[:space:]]*image: prom\/prometheus$/ {p; s/^([[:space:]]*).*/\1imagePullPolicy: IfNotPresent/;}' "$manifest"
  sed -i -E '/^[[:space:]]*image: grafana\/grafana:latest$/ {p; s/^([[:space:]]*).*/\1imagePullPolicy: IfNotPresent/;}' "$manifest"
  KUBECONFIG="$KUBECONFIG" AUDIT_EXPORTER_IMAGE=volcanosh/kube-apiserver-audit-exporter:dev \
    bash "$CHECKOUT/benchmark/scripts/install-monitoring.sh" 2>&1 | tee "$OUTPUT_DIR/monitoring-install-$number.log"
}

resolve_benchmark_config() {
  local configured="$1" number="$2" result
  if [[ "$configured" == GENERATED_POD ]]; then
    result="$WORK_DIR/pod-case-$number.yaml"
    sed -e "s/\${PODS}/$PODS/g" -e "s/\${SCHEDULER_NAME}/$SCHEDULER_NAME/g" \
      "$CHECKOUT/benchmark/testcases/pod/cases/case-template.yaml" > "$result"
  elif [[ "$configured" == /* ]]; then result="$configured"
  else result="$CHECKOUT/$configured"; fi
  [[ -f "$result" ]] || die "Candidate Benchmark config is missing: $configured"
  printf '%s\n' "$result"
}

run_benchmark_one() {
  local scenario="$1" configured="$2" number="$3" name config round round_dir
  name="$(cluster_name "benchmark-${scenario,,}" "$number")"
  config="$(resolve_benchmark_config "$configured" "$number")"
  create_benchmark_cluster "$name" "$number"
  install_candidate "$number"
  log "creating Candidate Benchmark KWOK nodes"
  if [[ "$configured" == *net-topo* ]]; then
    (cd "$CHECKOUT/benchmark"; ENABLE_TOPOLOGY=true USE_EXISTING_CLUSTER=true make create-nodes) \
      2>&1 | tee "$OUTPUT_DIR/benchmark-infrastructure-$number.log"
    (cd "$CHECKOUT/benchmark"; make create-hypernodes) 2>&1 | tee "$OUTPUT_DIR/benchmark-hypernodes-$number.log"
  else
    (cd "$CHECKOUT/benchmark"; USE_EXISTING_CLUSTER=true make create-nodes) \
      2>&1 | tee "$OUTPUT_DIR/benchmark-infrastructure-$number.log"
  fi
  if has_image_key prometheus; then prepare_monitoring "$name" "$number"; fi
  for ((round=1; round<=BENCHMARK_ROUNDS; round++)); do
    printf -v round_dir '%s/benchmark-%02d-%s-round-%02d' "$OUTPUT_DIR" "$number" "$scenario" "$round"
    mkdir -p "$round_dir"
    log "running Candidate Benchmark $scenario round $round/$BENCHMARK_ROUNDS"
    (
      cd "$CHECKOUT/benchmark"
      set +e
      bash scripts/run-tests.sh "$scenario" "--config=$config"
      test_status=$?
      set -e
      [[ ! -d results ]] || cp -a results/. "$round_dir/"
      make clean-vcjobs || true
      exit "$test_status"
    ) 2>&1 | tee "$round_dir/run.log"
  done
  delete_cluster "benchmark-$number"
}

for ((index=0; index<${#E2E_RUNS[@]}; index++)); do run_e2e_one "${E2E_RUNS[$index]}" "$((index+1))"; done
for ((index=0; index<${#BENCHMARK_RUN_SCENARIOS[@]}; index++)); do
  run_benchmark_one "${BENCHMARK_RUN_SCENARIOS[$index]}" "${BENCHMARK_RUN_CONFIGS[$index]}" "$((index+1))"
done

cat > "$OUTPUT_DIR/summary.txt" <<EOF
status=passed
script_version=$SCRIPT_VERSION
profile=$PROFILE
mode=$MODE
kubernetes_version=$K8S_VERSION
kind_version=$KIND_VERSION
bundle_volcano_ref=$BUNDLED_VOLCANO_REF
bundle_volcano_commit=$BUNDLED_VOLCANO_COMMIT
candidate_repository=$VOLCANO_REPO
candidate_requested_ref=$REQUESTED_VOLCANO_REF
candidate_commit=$CANDIDATE_COMMIT
e2e_selection=$E2E_SELECTION
benchmark_selection=$BENCHMARK_SELECTION
benchmark_rounds=$BENCHMARK_ROUNDS
finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
log "completed successfully; results: $OUTPUT_DIR"
