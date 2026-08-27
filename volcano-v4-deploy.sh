#!/usr/bin/env bash
# Internal entrypoint: verify one dependency bundle, fetch the selected Volcano
# Candidate, build it locally and invoke the Candidate's own E2E/Benchmark code.
set -Eeuo pipefail

SCRIPT_VERSION="v4.3.0"
RESUME_STATE_FORMAT="2"
DEFAULT_VOLCANO_REPO="https://github.com/volcano-sh/volcano.git"
DEFAULT_GOPROXY="direct"
DEFAULT_GONOSUMDB="*"
DEFAULT_GOSUMDB="off"

log() { printf '[vpg4-deploy] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
valid_semver() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_mode() { [[ "$1" == e2e || "$1" == benchmark || "$1" == both ]]; }
valid_text() { [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *'|'* ]]; }

go_version_at_least() {
  local have="${1#go}" need="${2#go}"
  local have_major have_minor have_patch need_major need_minor need_patch
  [[ "$have" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || return 1
  have_major="${BASH_REMATCH[1]}"; have_minor="${BASH_REMATCH[2]}"; have_patch="${BASH_REMATCH[4]:-0}"
  [[ "$need" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || return 1
  need_major="${BASH_REMATCH[1]}"; need_minor="${BASH_REMATCH[2]}"; need_patch="${BASH_REMATCH[4]:-0}"
  (( have_major > need_major )) ||
    (( have_major == need_major && have_minor > need_minor )) ||
    (( have_major == need_major && have_minor == need_minor && have_patch >= need_patch ))
}

hash_values() { printf '%s\0' "$@" | sha256sum | awk '{print $1}'; }
state_get() {
  local key="$1"
  [[ -f "${STATE_FILE:-}" ]] || return 1
  awk -v key="$key" 'index($0,key "=")==1 {sub(/^[^=]*=/,""); print; exit}' "$STATE_FILE"
}
state_set() {
  local key="$1" value="$2" tmp
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid resume-state key: $key"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "invalid resume-state value: $key"
  tmp="${STATE_FILE}.tmp.$$"
  if [[ -f "$STATE_FILE" ]]; then
    awk -v key="$key" 'index($0,key "=")!=1' "$STATE_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}
stage_path() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid resume stage: $1"
  printf '%s/%s.done\n' "$STAGE_DIR" "$1"
}
stage_done() { [[ -f "$(stage_path "$1")" ]]; }
mark_stage() { printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(stage_path "$1")"; }

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
  --work-dir DIR              Use a new directory, or resume a saved v4 directory
  --keep-work-dir             Keep an automatically created resumable directory
  --keep-cluster              Keep/reuse the only Kind cluster and its work directory

Candidate selection:
  --volcano-ref REF           Required branch, tag or commit except cluster-only
  --volcano-repo URL          Default: official Volcano repository
  --goproxy VALUE             Default: GOPROXY environment, otherwise direct
  --gonosumdb VALUE           Default: *
  --gosumdb VALUE             Default: off

Manual operation:
  --cluster-only              Create and keep a normal Kind cluster; no Candidate
  --deploy-only               Build and install Candidate Volcano, then keep it

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

Normal tests and deploy-only need Bash, curl, git, Docker, tar, gzip,
sha256sum, make and basic POSIX tools. cluster-only does not need git or make.
Exact Kind, kubectl, Helm, jq and Go come from the bundle. The Candidate's
complete Go module graph and selected Ginkgo are first downloaded on the inner
host through its configured Go module source. Docker builders then consume a
temporary file proxy and never contact that HTTPS proxy. The generic bundle
contains no Volcano source or Go modules. Nothing is installed system-wide. A
saved work directory resumes only when its bundle and complete
run identity match. A saved cluster restarts the selected E2E suite or failed
Benchmark round; it cannot resume inside one Ginkgo spec or one go test process.
The two manual-operation modes always keep their work directory and cluster,
write manual-env.sh, and do not run E2E or Benchmark. cluster-only does not
fetch Volcano or download Go modules. deploy-only installs the selected
Candidate with its Helm chart and stops after the deployment becomes ready.
When multiple E2E types, Benchmark scenarios, or Benchmark rounds are selected,
a failed test batch is recorded and later batches still run. Fatal bundle,
dependency, build, resume-identity, or result-write failures still stop
immediately. Infrastructure failure reported from inside an E2E runner ends
that batch before later selected batches continue. The final exit status remains
nonzero when any test batch failed.
EOF
}

BUNDLE_INPUT=""; BUNDLE_URL=""; OUTPUT_DIR=""; WORK_DIR=""
KEEP_WORK_DIR=false; KEEP_CLUSTER=false; LIST_CAPABILITIES=false; RESUME_WORK=false
MANUAL_ACTION=""
MODE_OVERRIDE=""; E2E_TYPE_OVERRIDE=""; BENCHMARK_SCENARIO_OVERRIDE=""
BENCHMARK_CONFIG_OVERRIDE=""; BENCHMARK_ROUNDS=1; PODS=1000
SCHEDULER_NAME="agent-scheduler"; CLUSTER_PREFIX="volcano-v4"
VOLCANO_REPO="$DEFAULT_VOLCANO_REPO"; VOLCANO_REF=""
GOPROXY_VALUE="${GOPROXY:-$DEFAULT_GOPROXY}"
GONOSUMDB_VALUE="${GONOSUMDB:-$DEFAULT_GONOSUMDB}"
GOSUMDB_VALUE="${GOSUMDB:-$DEFAULT_GOSUMDB}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_INPUT="${2:-}"; shift 2 ;;
    --bundle-url) BUNDLE_URL="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --keep-work-dir) KEEP_WORK_DIR=true; shift ;;
    --keep-cluster) KEEP_CLUSTER=true; shift ;;
    --cluster-only)
      [[ -z "$MANUAL_ACTION" || "$MANUAL_ACTION" == cluster-only ]] || die "use only one manual operation"
      MANUAL_ACTION=cluster-only; shift
      ;;
    --deploy-only)
      [[ -z "$MANUAL_ACTION" || "$MANUAL_ACTION" == deploy-only ]] || die "use only one manual operation"
      MANUAL_ACTION=deploy-only; shift
      ;;
    --volcano-repo) VOLCANO_REPO="${2:-}"; shift 2 ;;
    --volcano-ref) VOLCANO_REF="${2:-}"; shift 2 ;;
    --mode) MODE_OVERRIDE="${2:-}"; shift 2 ;;
    --e2e-type) E2E_TYPE_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-scenario) BENCHMARK_SCENARIO_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-config|--benchmark-profile) BENCHMARK_CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --benchmark-rounds) BENCHMARK_ROUNDS="${2:-}"; shift 2 ;;
    --pods) PODS="${2:-}"; shift 2 ;;
    --scheduler-name) SCHEDULER_NAME="${2:-}"; shift 2 ;;
    --cluster-prefix) CLUSTER_PREFIX="${2:-}"; shift 2 ;;
    --goproxy) GOPROXY_VALUE="${2:-}"; shift 2 ;;
    --gonosumdb) GONOSUMDB_VALUE="${2:-}"; shift 2 ;;
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
valid_text "$GONOSUMDB_VALUE" || die "invalid --gonosumdb"
valid_text "$GOSUMDB_VALUE" || die "invalid --gosumdb"
valid_text "$VOLCANO_REPO" || die "invalid --volcano-repo"
[[ -z "$MODE_OVERRIDE" ]] || valid_mode "$MODE_OVERRIDE" || die "invalid --mode"
if [[ -n "$MANUAL_ACTION" ]]; then
  [[ "$LIST_CAPABILITIES" != true ]] || die "--list-capabilities cannot be combined with a manual operation"
  [[ -z "$MODE_OVERRIDE" && -z "$E2E_TYPE_OVERRIDE" && -z "$BENCHMARK_SCENARIO_OVERRIDE" && -z "$BENCHMARK_CONFIG_OVERRIDE" ]] || \
    die "E2E/Benchmark run selection cannot be combined with a manual operation"
  [[ "$BENCHMARK_ROUNDS" == 1 && "$PODS" == 1000 && "$SCHEDULER_NAME" == agent-scheduler ]] || \
    die "Benchmark tuning options cannot be combined with a manual operation"
  KEEP_CLUSTER=true; KEEP_WORK_DIR=true
fi
if [[ "$MANUAL_ACTION" == cluster-only ]]; then
  [[ -z "$VOLCANO_REF" ]] || die "--volcano-ref is not used with --cluster-only"
else
  valid_text "$VOLCANO_REF" || die "--volcano-ref is required"
fi

for command in curl tar gzip sha256sum awk sed grep sort mktemp; do need "$command"; done
[[ "$MANUAL_ACTION" == cluster-only ]] || need git
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "deployment requires Linux x86_64"

configure_build_proxy() {
  local git_proxy="" source="none"
  VPG_HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
  VPG_HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
  VPG_NO_PROXY="${NO_PROXY:-${no_proxy:-}}"
  if [[ -n "$VPG_HTTP_PROXY" || -n "$VPG_HTTPS_PROXY" ]]; then
    source="environment"
  else
    git_proxy="$(git config --get-urlmatch http.proxy https://github.com/ 2>/dev/null || true)"
    [[ -n "$git_proxy" ]] || git_proxy="$(git config --global --get http.proxy 2>/dev/null || true)"
    if [[ -n "$git_proxy" ]]; then
      valid_text "$git_proxy" && [[ ! "$git_proxy" =~ [[:space:]] ]] || die "invalid Git HTTP proxy configuration"
      VPG_HTTP_PROXY="$git_proxy"; VPG_HTTPS_PROXY="$git_proxy"; source="git-config"
    fi
  fi
  [[ -n "$VPG_HTTP_PROXY" ]] || VPG_HTTP_PROXY="$VPG_HTTPS_PROXY"
  [[ -n "$VPG_HTTPS_PROXY" ]] || VPG_HTTPS_PROXY="$VPG_HTTP_PROXY"
  export HTTP_PROXY="$VPG_HTTP_PROXY" HTTPS_PROXY="$VPG_HTTPS_PROXY" NO_PROXY="$VPG_NO_PROXY"
  export VPG_BUILD_PROXY_SOURCE="$source"
  if [[ "$source" == git-config ]]; then
    log "forwarding the Git-configured GitHub proxy into Candidate builds"
  elif [[ "$source" == environment ]]; then
    log "forwarding the HTTP proxy environment into Candidate builds"
  else
    log "no host HTTP or Git proxy was detected for Candidate builds"
  fi
}
if [[ "$MANUAL_ACTION" == cluster-only ]]; then
  VPG_HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
  VPG_HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
  VPG_NO_PROXY="${NO_PROXY:-${no_proxy:-}}"
  VPG_BUILD_PROXY_SOURCE="$([[ -n "$VPG_HTTP_PROXY" || -n "$VPG_HTTPS_PROXY" ]] && printf environment || printf none)"
  export HTTP_PROXY="$VPG_HTTP_PROXY" HTTPS_PROXY="$VPG_HTTPS_PROXY" NO_PROXY="$VPG_NO_PROXY"
  log "cluster-only skips Candidate build proxy discovery"
else
  configure_build_proxy
fi

AUTO_WORK=false
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d /tmp/volcano-v4-deploy.XXXXXX)"; AUTO_WORK=true
else
  if [[ -e "$WORK_DIR" ]]; then
    [[ -d "$WORK_DIR" ]] || die "work path is not a directory: $WORK_DIR"
    WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"; RESUME_WORK=true
  else
    mkdir -p "$WORK_DIR"; WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
  fi
fi
STATE_DIR="$WORK_DIR/.vpg4-state"; STATE_FILE="$STATE_DIR/run.env"; STAGE_DIR="$STATE_DIR/stages"
if [[ "$RESUME_WORK" == true ]]; then
  [[ -f "$STATE_FILE" ]] || die "existing work directory has no v4 resume state: $WORK_DIR"
  [[ -d "$STAGE_DIR" ]] || die "saved work directory has no resume stage directory"
  [[ "$(state_get STATE_FORMAT)" == "$RESUME_STATE_FORMAT" ]] || die "unsupported work-directory resume format"
  saved_output="$(state_get OUTPUT_DIR)"
  [[ -n "$saved_output" && -d "$saved_output" ]] || die "saved output directory is missing: $saved_output"
  if [[ -n "$OUTPUT_DIR" ]]; then
    [[ -d "$OUTPUT_DIR" ]] || die "resume output directory does not exist: $OUTPUT_DIR"
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
    [[ "$OUTPUT_DIR" == "$saved_output" ]] || die "resume output mismatch: expected $saved_output"
  else
    OUTPUT_DIR="$saved_output"
  fi
  log "resuming saved work directory: $WORK_DIR"
else
  mkdir -p "$STATE_DIR" "$STAGE_DIR"
  if [[ -z "$OUTPUT_DIR" ]]; then OUTPUT_DIR="./volcano-v4-results-$(date -u +%Y%m%d-%H%M%S)"; fi
  [[ ! -e "$OUTPUT_DIR" ]] || die "output already exists: $OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR"; OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
  state_set STATE_FORMAT "$RESUME_STATE_FORMAT"
  state_set OUTPUT_DIR "$OUTPUT_DIR"
fi
if [[ "$KEEP_CLUSTER" == true ]]; then KEEP_WORK_DIR=true; fi
printf 'source=%s\nhttp_configured=%s\nhttps_configured=%s\nresume=%s\n' \
  "$VPG_BUILD_PROXY_SOURCE" "$([[ -n "$HTTP_PROXY" ]] && printf true || printf false)" \
  "$([[ -n "$HTTPS_PROXY" ]] && printf true || printf false)" "$RESUME_WORK" > "$OUTPUT_DIR/build-proxy.txt"

CURRENT_CLUSTER=""; CLUSTER_CREATED=false
cleanup() {
  status=$?
  # Cleanup is project-scoped: the active Kind cluster and an automatic work
  # directory only. Never prune host Docker images or containerd storage.
  if [[ "$CLUSTER_CREATED" == true && "$KEEP_CLUSTER" != true && -n "$CURRENT_CLUSTER" ]] && command -v kind >/dev/null 2>&1; then
    log "deleting project cluster after interruption: $CURRENT_CLUSTER"
    kind delete cluster --name "$CURRENT_CLUSTER" >"$OUTPUT_DIR/kind-delete-trap.log" 2>&1 || true
    state_set ACTIVE_CLUSTER "" 2>/dev/null || true
    state_set ACTIVE_PURPOSE "" 2>/dev/null || true
  fi
  state_set LAST_STATUS "$status" 2>/dev/null || true
  state_set LAST_FINISHED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
  if [[ "$AUTO_WORK" == true && "$KEEP_WORK_DIR" != true ]]; then
    chmod -R u+w "$WORK_DIR" 2>/dev/null || true
    rm -rf -- "$WORK_DIR" || log "could not completely remove work directory: $WORK_DIR"
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
  if [[ "$RESUME_WORK" == true && -s "$BUNDLE_INPUT" ]]; then
    log "reusing the saved downloaded bundle"
  else
    log "downloading bundle"
    curl --fail --location --retry 3 --connect-timeout 30 -o "$BUNDLE_INPUT" "$BUNDLE_URL"
  fi
fi
if [[ -z "$BUNDLE_INPUT" ]]; then
  saved_bundle_root="$(state_get BUNDLE_ROOT 2>/dev/null || true)"
  if [[ "$RESUME_WORK" == true && -n "$saved_bundle_root" && -d "$saved_bundle_root" ]]; then
    BUNDLE_INPUT="$saved_bundle_root"
    log "reusing the saved extracted bundle"
  else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    [[ -f "$script_dir/bundle.meta" ]] || die "--bundle is required outside an extracted bundle or resumable work directory"
    BUNDLE_INPUT="$script_dir"
  fi
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

for required in bundle.meta images.tar.gz tools.tar.gz resources.tar.gz SHA256SUMS; do
  [[ -f "$BUNDLE_ROOT/$required" ]] || die "bundle is missing $required"
done
(cd "$BUNDLE_ROOT" && sha256sum -c SHA256SUMS)
BUNDLE_ID="$(sha256sum "$BUNDLE_ROOT/SHA256SUMS" | awk '{print $1}')"

FORMAT=""; BUNDLE_SCRIPT_VERSION=""; BUNDLE_SCOPE=""; PLATFORM=""; PROFILE=""; PACKAGED_MODE=""; DEFAULT_RUN=""
K8S_VERSION=""; KIND_VERSION=""; HELM_VERSION=""; JQ_VERSION=""; KWOK_VERSION=""; GO_TOOLCHAIN=""
IMAGE_KEYS=(); IMAGE_PULL_REFS=(); IMAGE_SAVE_REFS=(); IMAGE_IDS=()
TOOL_KEYS=(); TOOL_VERSIONS=(); TOOL_PATHS=(); TOOL_SHA256S=()
RESOURCE_KEYS=(); RESOURCE_PATHS=(); RESOURCE_SHA256S=()
E2E_CAPS=(); BENCHMARK_CAP_SCENARIOS=(); BENCHMARK_CAP_CONFIGS=()
while IFS='=' read -r name value; do
  [[ -n "$name" ]] || continue
  case "$name" in
    FORMAT) FORMAT="$value" ;;
    SCRIPT_VERSION) BUNDLE_SCRIPT_VERSION="$value" ;;
    BUNDLE_SCOPE) BUNDLE_SCOPE="$value" ;;
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
[[ "$BUNDLE_SCOPE" == generic ]] || die "bundle is not a generic v4 dependency bundle"
[[ "$PLATFORM" == linux/amd64 ]] || die "unsupported bundle platform: $PLATFORM"
valid_text "$PROFILE" || die "invalid profile metadata"
valid_mode "$PACKAGED_MODE" || die "invalid mode metadata"
valid_semver "$K8S_VERSION" || die "invalid Kubernetes version metadata"
valid_semver "$KIND_VERSION" || die "invalid Kind version metadata"
valid_semver "$HELM_VERSION" || die "invalid Helm version metadata"
valid_semver "$KWOK_VERSION" || die "invalid KWOK version metadata"
[[ "$JQ_VERSION" =~ ^jq-[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid jq version metadata"
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid Go version metadata"
[[ "$K8S_VERSION" =~ ^v[0-9]+\.([0-9]+)\.[0-9]+$ ]] || die "invalid Kubernetes version metadata: $K8S_VERSION"
K8S_MINOR="${BASH_REMATCH[1]}"
[[ ${#IMAGE_KEYS[@]} -gt 0 ]] || die "bundle contains no images"
[[ ${#TOOL_KEYS[@]} -eq 5 ]] || die "bundle must contain exactly five tools"

MODE="${MODE_OVERRIDE:-$PACKAGED_MODE}"
if [[ "$PACKAGED_MODE" != both && "$MODE" != "$PACKAGED_MODE" ]]; then die "requested mode $MODE is not covered by profile $PROFILE"; fi
[[ "$MODE" == benchmark || ${#E2E_CAPS[@]} -gt 0 ]] || die "bundle has no E2E capability"
[[ "$MODE" == e2e || ${#BENCHMARK_CAP_SCENARIOS[@]} -gt 0 ]] || die "bundle has no Benchmark capability"

if [[ -n "$MANUAL_ACTION" ]]; then
  RUN_ID="$(hash_values "$SCRIPT_VERSION" "$BUNDLE_ID" "manual-action" "$MANUAL_ACTION" \
    "$VOLCANO_REPO" "$VOLCANO_REF" "$CLUSTER_PREFIX")"
else
  # Preserve the existing test-run identity so work directories saved by the
  # previous v4.3.0 script remain resumable.
  RUN_ID="$(hash_values "$SCRIPT_VERSION" "$BUNDLE_ID" "$VOLCANO_REPO" "$VOLCANO_REF" "$MODE" \
    "$E2E_TYPE_OVERRIDE" "$BENCHMARK_SCENARIO_OVERRIDE" "$BENCHMARK_CONFIG_OVERRIDE" \
    "$BENCHMARK_ROUNDS" "$PODS" "$SCHEDULER_NAME" "$CLUSTER_PREFIX")"
fi
if [[ "$RESUME_WORK" == true ]]; then
  saved_run_id="$(state_get RUN_ID)"
  if [[ -z "$saved_run_id" ]]; then
    shopt -s nullglob; saved_stages=("$STAGE_DIR"/*.done); shopt -u nullglob
    [[ ${#saved_stages[@]} -eq 0 ]] || die "saved work directory has stages but no run identity"
    state_set RUN_ID "$RUN_ID"
    state_set BUNDLE_ID "$BUNDLE_ID"
    log "initialized resume identity after an early previous interruption"
  else
    [[ "$saved_run_id" == "$RUN_ID" ]] || die "saved work directory belongs to a different bundle, Candidate, mode, or run selection"
  fi
else
  state_set RUN_ID "$RUN_ID"
  state_set BUNDLE_ID "$BUNDLE_ID"
  state_set VOLCANO_REPOSITORY_HASH "$(hash_values "$VOLCANO_REPO")"
  state_set VOLCANO_REF_HASH "$(hash_values "$VOLCANO_REF")"
  state_set PROFILE "$PROFILE"
  state_set MODE "$MODE"
  state_set ACTION "${MANUAL_ACTION:-test}"
  state_set KUBERNETES_VERSION "$K8S_VERSION"
fi
state_set BUNDLE_ROOT "$BUNDLE_ROOT"
if [[ "$RESUME_WORK" == true && -n "$(state_get ACTIVE_CLUSTER)" && "$KEEP_CLUSTER" != true ]]; then
  die "saved work directory records an active Kind cluster; add --keep-cluster to validate and reuse it"
fi

printf 'bundle_scope=%s\nprofile=%s\nmode=%s\ndefault_run=%s\n' \
  "$BUNDLE_SCOPE" "$PROFILE" "$PACKAGED_MODE" "$DEFAULT_RUN"
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
bundle_scope=$BUNDLE_SCOPE
EOF
  log "capabilities verified; no Docker operation was performed"
  exit 0
fi

need docker; need tee
[[ "$MANUAL_ACTION" == cluster-only ]] || need make
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

AVAILABLE_KIND_VERSIONS=(); AVAILABLE_KIND_PATHS=()
AVAILABLE_GO_VERSIONS=(); AVAILABLE_GO_PATHS=()
add_packaged_toolchain() {
  local type="$1" version="$2" path="$3" existing
  case "$type" in
    KIND)
      for existing in "${AVAILABLE_KIND_VERSIONS[@]}"; do [[ "$existing" != "$version" ]] || die "duplicate packaged KIND version: $version"; done
      AVAILABLE_KIND_VERSIONS+=("$version"); AVAILABLE_KIND_PATHS+=("$path")
      ;;
    GO)
      for existing in "${AVAILABLE_GO_VERSIONS[@]}"; do [[ "$existing" != "$version" ]] || die "duplicate packaged GO version: $version"; done
      AVAILABLE_GO_VERSIONS+=("$version"); AVAILABLE_GO_PATHS+=("$path")
      ;;
    *) die "unknown packaged toolchain type: $type" ;;
  esac
}
TOOLCHAIN_MANIFEST="$TOOLS_DIR/toolchains.tsv"
MULTI_TOOLCHAIN_MANIFEST=false
if [[ -f "$TOOLCHAIN_MANIFEST" ]]; then
  MULTI_TOOLCHAIN_MANIFEST=true
  while IFS='|' read -r type version path expected extra; do
    [[ -n "$type" && "$type" != \#* ]] || continue
    [[ -z "$extra" ]] || die "invalid toolchains.tsv record"
    case "$type" in
      KIND) valid_semver "$version" || die "invalid packaged Kind version: $version" ;;
      GO) [[ "$version" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid packaged Go version: $version" ;;
      *) die "unknown toolchains.tsv type: $type" ;;
    esac
    [[ -n "$path" && "$path" != /* && "$path" != ../* && "$path" != *'/../'* ]] || die "unsafe toolchain path: $path"
    [[ "$expected" =~ ^[0-9a-f]{64}$ && -f "$TOOLS_DIR/$path" ]] || die "invalid packaged toolchain: $type $version"
    [[ "$(sha256sum "$TOOLS_DIR/$path" | awk '{print $1}')" == "$expected" ]] || die "toolchain checksum mismatch: $type $version"
    add_packaged_toolchain "$type" "$version" "$path"
  done < "$TOOLCHAIN_MANIFEST"
else
  # v4.3.0 bundles made before the multi-tool manifest remain usable.
  for ((index=0; index<${#TOOL_KEYS[@]}; index++)); do
    case "${TOOL_KEYS[$index]}" in
      kind) add_packaged_toolchain KIND "${TOOL_VERSIONS[$index]}" "${TOOL_PATHS[$index]}" ;;
      go) add_packaged_toolchain GO "${TOOL_VERSIONS[$index]}" "${TOOL_PATHS[$index]}" ;;
    esac
  done
fi

packaged_toolchain_path() {
  local type="$1" wanted="$2" index
  case "$type" in
    KIND)
      for ((index=0; index<${#AVAILABLE_KIND_VERSIONS[@]}; index++)); do
        [[ "${AVAILABLE_KIND_VERSIONS[$index]}" != "$wanted" ]] || { printf '%s\n' "${AVAILABLE_KIND_PATHS[$index]}"; return; }
      done
      ;;
    GO)
      for ((index=0; index<${#AVAILABLE_GO_VERSIONS[@]}; index++)); do
        [[ "${AVAILABLE_GO_VERSIONS[$index]}" != "$wanted" ]] || { printf '%s\n' "${AVAILABLE_GO_PATHS[$index]}"; return; }
      done
      ;;
  esac
  return 1
}

KIND_RELATIVE_PATH="$(packaged_toolchain_path KIND "$KIND_VERSION")" || die "bundle does not contain selected Kind $KIND_VERSION"
DEFAULT_GO_RELATIVE_PATH="$(packaged_toolchain_path GO "$GO_TOOLCHAIN")" || die "bundle does not contain default Go $GO_TOOLCHAIN"
KIND_BINARY="$TOOLS_DIR/$KIND_RELATIVE_PATH"
for path in "${AVAILABLE_KIND_PATHS[@]}"; do chmod 0755 "$TOOLS_DIR/$path"; done
for path in "${AVAILABLE_GO_PATHS[@]}"; do
  go_root="$TOOLS_DIR/$(dirname "$(dirname "$path")")"
  [[ -d "$go_root/bin" && -d "$go_root/pkg/tool/linux_amd64" ]] || die "packaged Go toolchain is incomplete: $path"
  chmod 0755 "$go_root/bin/"* "$go_root/pkg/tool/linux_amd64/"*
done
chmod 0755 "$BIN_DIR/kubectl" "$BIN_DIR/helm" "$BIN_DIR/jq"

VPG_BASE_PATH="$PATH"
export GOTOOLCHAIN=local GOPATH="$WORK_DIR/gopath"
export GOMODCACHE="$WORK_DIR/go-mod-cache" GOCACHE="$WORK_DIR/go-build-cache"
export GOPROXY="$GOPROXY_VALUE" GONOSUMDB="$GONOSUMDB_VALUE" GOSUMDB="$GOSUMDB_VALUE"
activate_go_toolchain() {
  local version="$1" relative_path="$2"
  SELECTED_GO_TOOLCHAIN="$version"
  GOROOT="$TOOLS_DIR/$(dirname "$(dirname "$relative_path")")"
  export SELECTED_GO_TOOLCHAIN GOROOT
  export PATH="$GOROOT/bin:$GOPATH/bin:$(dirname "$KIND_BINARY"):$BIN_DIR:$VPG_BASE_PATH"
}
activate_go_toolchain "$GO_TOOLCHAIN" "$DEFAULT_GO_RELATIVE_PATH"

kind version | tee "$OUTPUT_DIR/kind-version.log"
kind version | grep -F "$KIND_VERSION" >/dev/null || die "Kind version mismatch"
kubectl version --client -o json > "$OUTPUT_DIR/kubectl-version.json"
[[ "$(jq -r '.clientVersion.gitVersion' "$OUTPUT_DIR/kubectl-version.json")" == "$K8S_VERSION" ]] || die "kubectl version mismatch"
helm version --short | tee "$OUTPUT_DIR/helm-version.log"
helm version --short | grep -F "$HELM_VERSION" >/dev/null || die "Helm version mismatch"
[[ "$(jq --version)" == "$JQ_VERSION" ]] || die "jq version mismatch"
go version | tee "$OUTPUT_DIR/go-default-version.log"
go version | grep -F " $GO_TOOLCHAIN " >/dev/null || die "Go version mismatch"

# Classic Docker stores report the image config digest as .Id. Docker 29 with
# the containerd image store can instead report a host-local OCI descriptor
# digest, which is not stable across save/load or hosts. The bundle hash and
# config digest remain stable, so normalize only mismatched IDs by streaming
# the loaded tags through docker save and comparing their config digests.
IMAGE_ARCHIVE_MANIFEST="$WORK_DIR/image-manifest.json"
LOADED_IMAGE_MANIFEST="$WORK_DIR/loaded-image-manifest.json"
LOADED_IMAGE_MANIFEST_READY=false

image_config_id_from_manifest() {
  local manifest="$1" ref="$2" config_path config_hash
  # Docker archive manifests may omit the docker.io registry prefix and the
  # implicit library namespace even when bundle.meta uses the fully qualified
  # spelling. Compare canonical Docker Hub names while leaving other registry
  # references unchanged.
  config_path="$(jq -er --arg ref "$ref" '
    def canonical_ref:
      sub("^index\\.docker\\.io/"; "")
      | sub("^docker\\.io/"; "")
      | if test("/") then . else "library/" + . end;
    ($ref | canonical_ref) as $wanted
    | [.[]
       | select(any((.RepoTags // [])[]; canonical_ref == $wanted))
       | .Config]
    | unique
    | if length == 1 then .[0] else error("missing") end
  ' "$manifest")" || return 1
  config_hash="${config_path##*/}"
  config_hash="${config_hash%.json}"
  [[ "$config_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'sha256:%s\n' "$config_hash"
}

write_loaded_image_manifest() {
  local ref existing duplicate
  local -a refs=()
  [[ "$LOADED_IMAGE_MANIFEST_READY" != true ]] || return 0
  for ref in "${IMAGE_SAVE_REFS[@]}"; do
    duplicate=false
    if [[ ${#refs[@]} -gt 0 ]]; then
      for existing in "${refs[@]}"; do
        if [[ "$existing" == "$ref" ]]; then duplicate=true; break; fi
      done
    fi
    [[ "$duplicate" == true ]] || refs+=("$ref")
  done
  [[ ${#refs[@]} -gt 0 ]] || die "cannot normalize an empty loaded image list"
  log "normalizing Docker containerd image identities through config digests"
  if docker image save --help 2>&1 | grep -q -- '--platform'; then
    docker image save --platform=linux/amd64 "${refs[@]}" | tar -xOf - manifest.json > "$LOADED_IMAGE_MANIFEST"
  else
    docker image save "${refs[@]}" | tar -xOf - manifest.json > "$LOADED_IMAGE_MANIFEST"
  fi
  jq -e 'type=="array" and length>0' "$LOADED_IMAGE_MANIFEST" >/dev/null || die "invalid loaded image manifest"
  LOADED_IMAGE_MANIFEST_READY=true
}

gzip -dc "$BUNDLE_ROOT/images.tar.gz" | tar -xOf - manifest.json > "$IMAGE_ARCHIVE_MANIFEST"
jq -e 'type=="array" and length>0' "$IMAGE_ARCHIVE_MANIFEST" >/dev/null || die "invalid image archive manifest"
gzip -dc "$BUNDLE_ROOT/images.tar.gz" | docker image load | tee "$OUTPUT_DIR/docker-load.log"
NODE_IMAGE=""
for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
  key="${IMAGE_KEYS[$index]}"; save_ref="${IMAGE_SAVE_REFS[$index]}"; expected_id="${IMAGE_IDS[$index]}"
  [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ && "$expected_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid image metadata"
  config_id="$(image_config_id_from_manifest "$IMAGE_ARCHIVE_MANIFEST" "$save_ref")" || die "archive image identity missing: $save_ref"
  observed="$(docker image inspect --format '{{.Os}}/{{.Architecture}}|{{.Id}}' "$save_ref")"
  [[ "${observed%%|*}" == linux/amd64 ]] || die "image platform mismatch: $save_ref"
  observed_id="${observed#*|}"
  if [[ "$observed_id" != "$expected_id" && "$observed_id" != "$config_id" ]]; then
    write_loaded_image_manifest
    loaded_config_id="$(image_config_id_from_manifest "$LOADED_IMAGE_MANIFEST" "$save_ref")" || die "loaded image identity missing: $save_ref"
    [[ "$loaded_config_id" == "$config_id" ]] || die "loaded image config mismatch: $save_ref"
  fi
  [[ "$key" != kind-node ]] || NODE_IMAGE="$save_ref"
done
[[ -n "$NODE_IMAGE" ]] || die "bundle does not contain kind-node"

has_image_key() { local wanted="$1" x; for x in "${IMAGE_KEYS[@]}"; do [[ "$x" == "$wanted" ]] && return 0; done; return 1; }
bundle_has_image_ref() {
  local wanted="${1%@*}" i
  for ((i=0; i<${#IMAGE_SAVE_REFS[@]}; i++)); do
    [[ "${IMAGE_SAVE_REFS[$i]%@*}" != "$wanted" ]] || return 0
  done
  return 1
}
resource_for_key() { local wanted="$1" i; for ((i=0;i<${#RESOURCE_KEYS[@]};i++)); do [[ "${RESOURCE_KEYS[$i]}" != "$wanted" ]] || { printf '%s\n' "$RESOURCES_DIR/${RESOURCE_PATHS[$i]}"; return; }; done; return 1; }

cluster_exists() { kind get clusters 2>/dev/null | grep -Fxq "$1"; }

manual_cluster_name() {
  local suffix="$1" name
  suffix="${suffix//./-}"
  name="${CLUSTER_PREFIX}-${suffix}"
  name="${name:0:27}"
  printf '%s\n' "${name%-}"
}

record_manual_cluster_identity() {
  local kubeconfig="$1" purpose="$2" commit="${CANDIDATE_COMMIT:-}"
  kubectl --kubeconfig "$kubeconfig" -n kube-system create configmap vpg4-resume-state \
    --from-literal="run-id=$RUN_ID" --from-literal="candidate-commit=$commit" \
    --from-literal="purpose=$purpose" --dry-run=client -o yaml | \
    kubectl --kubeconfig "$kubeconfig" apply -f - >/dev/null
}

validate_manual_cluster() {
  local name="$1" purpose="$2" kubeconfig="$3" observed identity commit="${CANDIDATE_COMMIT:-}"
  [[ "$RESUME_WORK" == true ]] || die "manual cluster already exists: $name; use its saved --work-dir or delete it explicitly"
  [[ "$(state_get ACTIVE_CLUSTER)" == "$name" && "$(state_get ACTIVE_PURPOSE)" == "$purpose" ]] || \
    die "saved manual-cluster identity does not match $name"
  kind get kubeconfig --name "$name" > "$kubeconfig"
  chmod 0600 "$kubeconfig"
  observed="$(kubectl --kubeconfig "$kubeconfig" version -o json | jq -r '.serverVersion.gitVersion')"
  [[ "$observed" == "$K8S_VERSION" ]] || die "saved cluster Kubernetes mismatch: expected $K8S_VERSION, got $observed"
  identity="$(kubectl --kubeconfig "$kubeconfig" -n kube-system get configmap vpg4-resume-state -o json)" || \
    die "saved manual cluster has no v4 identity: $name"
  jq -e --arg run "$RUN_ID" --arg commit "$commit" --arg purpose "$purpose" \
    '.data["run-id"]==$run and .data["candidate-commit"]==$commit and .data.purpose==$purpose' \
    <<< "$identity" >/dev/null || die "saved manual cluster belongs to a different operation"
  log "validated and reusing manual Kind cluster: $name"
}

create_manual_cluster() {
  local name="$1" purpose="$2" kubeconfig="$3" config observed saved_active
  MANUAL_CLUSTER_REUSED=false
  config="$WORK_DIR/kind-${MANUAL_ACTION}.yaml"
  cat > "$config" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
  CURRENT_CLUSTER="$name"; CLUSTER_CREATED=true
  if cluster_exists "$name"; then
    validate_manual_cluster "$name" "$purpose" "$kubeconfig"
    MANUAL_CLUSTER_REUSED=true
  else
    saved_active="$(state_get ACTIVE_CLUSTER 2>/dev/null || true)"
    [[ -z "$saved_active" || "$saved_active" == "$name" ]] || \
      die "saved work directory belongs to another manual cluster: $saved_active"
    if [[ "$saved_active" == "$name" ]]; then
      log "saved manual cluster is absent; recreating the same verified cluster: $name"
    fi
    state_set ACTIVE_CLUSTER "$name"; state_set ACTIVE_PURPOSE "$purpose"
    log "creating persistent manual Kind cluster: $name"
    kind create cluster --name "$name" --image "$NODE_IMAGE" --config "$config" --wait 300s \
      2>&1 | tee "$OUTPUT_DIR/kind-create-${MANUAL_ACTION}.log"
    kind get kubeconfig --name "$name" > "$kubeconfig"
    chmod 0600 "$kubeconfig"
    observed="$(kubectl --kubeconfig "$kubeconfig" version -o json | jq -r '.serverVersion.gitVersion')"
    [[ "$observed" == "$K8S_VERSION" ]] || die "Kubernetes version mismatch: expected $K8S_VERSION, got $observed"
    record_manual_cluster_identity "$kubeconfig" "$purpose"
  fi
  KUBECONFIG="$kubeconfig"; export KUBECONFIG
}

write_manual_access() {
  local name="$1" kubeconfig="$2" env_file access_file kind_dir
  env_file="$OUTPUT_DIR/manual-env.sh"; access_file="$OUTPUT_DIR/manual-access.txt"
  kind_dir="$(dirname "$KIND_BINARY")"
  {
    printf '# Generated by volcano-v4-deploy.sh; source this file in Bash.\n'
    printf 'export VPG4_WORK_DIR=%q\n' "$WORK_DIR"
    printf 'export VPG4_KIND_CLUSTER=%q\n' "$name"
    printf 'export KUBECONFIG=%q\n' "$kubeconfig"
    printf 'export GOROOT=%q\n' "$GOROOT"
    printf 'export GOPATH=%q\n' "$GOPATH"
    printf 'export PATH=%q:%q:%q:%q:$PATH\n' "$GOROOT/bin" "$GOPATH/bin" "$kind_dir" "$BIN_DIR"
  } > "$env_file"
  chmod 0644 "$env_file"
  {
    printf 'source %q\n' "$env_file"
    printf 'kubectl get nodes -o wide\n'
    [[ "$MANUAL_ACTION" != deploy-only ]] || printf 'kubectl -n volcano-system get pods -o wide\n'
    printf 'kind delete cluster --name %q\n' "$name"
  } > "$access_file"
  state_set MANUAL_ENV_FILE "$env_file"
  log "manual environment: $env_file"
  log "run: source $(printf '%q' "$env_file")"
}

finish_manual_action() {
  local name="$1" kubeconfig="$2" commit="${CANDIDATE_COMMIT:-}"
  write_manual_access "$name" "$kubeconfig"
  cat > "$OUTPUT_DIR/summary.txt" <<EOF
status=ready
script_version=$SCRIPT_VERSION
action=$MANUAL_ACTION
bundle_scope=$BUNDLE_SCOPE
profile=$PROFILE
kubernetes_version=$K8S_VERSION
kind_version=$KIND_VERSION
default_go_toolchain=$GO_TOOLCHAIN
selected_go_toolchain=$SELECTED_GO_TOOLCHAIN
candidate_repository=$([[ "$MANUAL_ACTION" == deploy-only ]] && printf '%s' "$VOLCANO_REPO" || true)
candidate_requested_ref=$VOLCANO_REF
candidate_commit=$commit
cluster_name=$name
kubeconfig=$kubeconfig
work_directory=$WORK_DIR
manual_environment=$OUTPUT_DIR/manual-env.sh
finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  mark_stage "manual-${MANUAL_ACTION}-ready"
  log "$MANUAL_ACTION completed; cluster $name is ready for normal Kind/kubectl use"
  exit 0
}

if [[ "$MANUAL_ACTION" == cluster-only ]]; then
  manual_name="$(manual_cluster_name "kind-${K8S_VERSION#v}")"
  manual_kubeconfig="$OUTPUT_DIR/kubeconfig"
  create_manual_cluster "$manual_name" cluster-only "$manual_kubeconfig"
  finish_manual_action "$manual_name" "$manual_kubeconfig"
fi

CHECKOUT="$WORK_DIR/volcano"
if stage_done candidate-checkout; then
  CANDIDATE_COMMIT="$(state_get CANDIDATE_COMMIT)"
  [[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ && -d "$CHECKOUT/.git" ]] || die "saved Candidate checkout is incomplete"
  [[ "$(git -C "$CHECKOUT" rev-parse HEAD)" == "$CANDIDATE_COMMIT" ]] || die "saved Candidate checkout commit changed"
  [[ "$(git -C "$CHECKOUT" remote get-url origin)" == "$VOLCANO_REPO" ]] || die "saved Candidate repository changed"
  log "reusing Candidate checkout: $CANDIDATE_COMMIT"
else
  if [[ -e "$CHECKOUT" ]]; then
    [[ -d "$CHECKOUT/.git" ]] || die "partial Candidate checkout is not resumable: $CHECKOUT"
    [[ -z "$(git -C "$CHECKOUT" status --porcelain)" ]] || die "uncheckpointed Candidate checkout is dirty; use a new work directory"
    [[ "$(git -C "$CHECKOUT" remote get-url origin)" == "$VOLCANO_REPO" ]] || die "partial Candidate repository does not match"
  else
    git init "$CHECKOUT" >/dev/null
    git -C "$CHECKOUT" remote add origin "$VOLCANO_REPO"
  fi
  log "fetching Volcano Candidate: $VOLCANO_REF"
  git -C "$CHECKOUT" fetch --depth 1 origin "$VOLCANO_REF"
  git -C "$CHECKOUT" checkout --detach FETCH_HEAD
  CANDIDATE_COMMIT="$(git -C "$CHECKOUT" rev-parse HEAD)"
  [[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve selected Candidate"
  if [[ -f "$CHECKOUT/.gitmodules" ]]; then git -C "$CHECKOUT" submodule update --init --recursive --depth 1; fi
  state_set CANDIDATE_COMMIT "$CANDIDATE_COMMIT"
  mark_stage candidate-checkout
fi
if [[ ! -f "$OUTPUT_DIR/candidate-status-before-environment-patch.txt" ]]; then
  git -C "$CHECKOUT" status --short > "$OUTPUT_DIR/candidate-status-before-environment-patch.txt"
fi
printf '%s\n' "$CANDIDATE_COMMIT" > "$OUTPUT_DIR/candidate-commit.txt"

CANDIDATE_GO="$(awk '$1=="toolchain"&&NF==2 {print $2;exit}' "$CHECKOUT/go.mod")"
[[ -n "$CANDIDATE_GO" ]] || CANDIDATE_GO="go$(awk '$1=="go"&&NF==2 {print $2;exit}' "$CHECKOUT/go.mod")"
select_candidate_go_toolchain() {
  local candidate="$1" candidate_major candidate_minor version path index
  local selected_version="" selected_path=""
  [[ "$candidate" =~ ^go([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || die "invalid Candidate Go version: $candidate"
  candidate_major="${BASH_REMATCH[1]}"; candidate_minor="${BASH_REMATCH[2]}"
  for ((index=0; index<${#AVAILABLE_GO_VERSIONS[@]}; index++)); do
    version="${AVAILABLE_GO_VERSIONS[$index]}"; path="${AVAILABLE_GO_PATHS[$index]}"
    [[ "$version" =~ ^go([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
    [[ "${BASH_REMATCH[1]}" == "$candidate_major" && "${BASH_REMATCH[2]}" == "$candidate_minor" ]] || continue
    go_version_at_least "$version" "$candidate" || continue
    if [[ -z "$selected_version" ]] || go_version_at_least "$selected_version" "$version"; then
      selected_version="$version"; selected_path="$path"
    fi
  done
  if [[ -z "$selected_version" && "$MULTI_TOOLCHAIN_MANIFEST" != true ]] && \
     go_version_at_least "$GO_TOOLCHAIN" "$candidate"; then
    selected_version="$GO_TOOLCHAIN"; selected_path="$DEFAULT_GO_RELATIVE_PATH"
    log "legacy bundle has one Go toolchain; using backward-compatible $selected_version for Candidate minimum $candidate"
  fi
  [[ -n "$selected_version" ]] || \
    die "bundle has no Go toolchain in Candidate-required line $candidate; add it to config/versions.tsv and rebuild the generic bundle"
  activate_go_toolchain "$selected_version" "$selected_path"
  log "selected packaged Go $SELECTED_GO_TOOLCHAIN for Candidate minimum $candidate"
}
select_candidate_go_toolchain "$CANDIDATE_GO"
state_set SELECTED_GO_TOOLCHAIN "$SELECTED_GO_TOOLCHAIN"
printf 'kind=%s\navailable_kind=%s\ndefault_go=%s\nselected_go=%s\navailable_go=%s\n' \
  "$KIND_VERSION" "$(IFS=,; printf '%s' "${AVAILABLE_KIND_VERSIONS[*]}")" "$GO_TOOLCHAIN" \
  "$SELECTED_GO_TOOLCHAIN" "$(IFS=,; printf '%s' "${AVAILABLE_GO_VERSIONS[*]}")" \
  > "$OUTPUT_DIR/selected-toolchains.txt"
go version | tee "$OUTPUT_DIR/go-version.log"
go version | grep -F " $SELECTED_GO_TOOLCHAIN " >/dev/null || die "selected Go version mismatch"
go tool compile -V=full | tee "$OUTPUT_DIR/go-compile-version.log"
go env GOPROXY GONOSUMDB GOSUMDB GOTOOLCHAIN GOOS GOARCH > "$OUTPUT_DIR/go-environment.txt"

# Resolve the complete Candidate module graph on the inner host, where the
# approved corporate proxy and CA trust have already been verified. The
# standard cache/download tree is itself a GOPROXY file proxy, so Docker
# builders can consume it without contacting the HTTPS proxy or trusting its
# corporate CA.
VPG_INNER_GO_MODULE_ARCHIVE="$WORK_DIR/inner-go-modules.tar.gz"
if stage_done go-modules; then
  [[ -d "$GOMODCACHE/cache/download" ]] || die "saved Go module cache is missing"
  log "reusing the complete saved Candidate Go module graph"
else
  log "downloading the Candidate Go module graph on the inner host through GOPROXY"
  (
    cd "$CHECKOUT"
    go mod download all
  ) 2>&1 | tee -a "$OUTPUT_DIR/go-mod-download.log"
  [[ -d "$GOMODCACHE/cache/download" ]] || die "inner-host Go module proxy cache was not created"
  mark_stage go-modules
fi
[[ -d "$GOMODCACHE/cache/download" ]] || die "inner-host Go module proxy cache was not created"
tar -C "$GOMODCACHE/cache/download" --exclude='*.lock' --exclude='*.tmp' \
  -czf "$VPG_INNER_GO_MODULE_ARCHIVE" .
[[ -s "$VPG_INNER_GO_MODULE_ARCHIVE" ]] || die "inner-host Go module proxy archive is empty"
sha256sum "$VPG_INNER_GO_MODULE_ARCHIVE" | awk '{print $1 "  inner-go-modules.tar.gz"}' \
  > "$OUTPUT_DIR/inner-go-modules.sha256"
log "prepared the inner-host Go module file proxy for Candidate Docker builds"

if [[ "$MANUAL_ACTION" != deploy-only && "$MODE" != benchmark ]]; then
  GINKGO_VERSION="$(awk '$1=="github.com/onsi/ginkgo/v2" {print $2;exit} $1=="require"&&$2=="github.com/onsi/ginkgo/v2" {print $3;exit}' "$CHECKOUT/go.mod")"
  [[ "$GINKGO_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "cannot resolve Candidate Ginkgo version"
  if stage_done ginkgo; then
    [[ -x "$GOPATH/bin/ginkgo" ]] || die "saved Ginkgo binary is missing"
    log "reusing Candidate-selected Ginkgo $GINKGO_VERSION"
  else
    log "installing Candidate-selected Ginkgo $GINKGO_VERSION through GOPROXY"
    go install "github.com/onsi/ginkgo/v2/ginkgo@$GINKGO_VERSION"
    mark_stage ginkgo
  fi
  ginkgo version | tee "$OUTPUT_DIR/ginkgo-version.log"
fi

# Treat each upstream E2E Make target as the Candidate's execution contract.
# This follows per-release feature gates, ignored provisioners, sharding modes
# and non-image prerequisites without maintaining a Volcano version table.
E2E_CONTRACT_DIR="$WORK_DIR/e2e-contracts"
E2E_CONTRACT_REPORT="$OUTPUT_DIR/candidate-e2e-contracts.txt"
E2E_CONTRACT_KEYS=(E2E_TYPE FEATURE_GATES IGNORED_PROVISIONERS SHARDING_MODE DRA_GINKGO_FOCUS)
RESOLVED_E2E_TARGET=""; RESOLVED_E2E_ERROR=""; RESOLVED_E2E_MAKE_ARGS=()

e2e_contract_path() {
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  printf '%s/%s.tsv\n' "$E2E_CONTRACT_DIR" "${1,,}"
}

e2e_make_target_for_type() {
  local type="$1" suffix
  RESOLVED_E2E_MAKE_ARGS=()
  case "$type" in
    ALL) RESOLVED_E2E_TARGET=e2e ;;
    AGENTSCHEDULER) RESOLVED_E2E_TARGET=e2e-test-agentscheduler ;;
    AGENTSCHEDULER_NONE|AGENTSCHEDULER_SOFT|AGENTSCHEDULER_HARD)
      RESOLVED_E2E_TARGET=e2e-test-agentscheduler
      suffix="${type#AGENTSCHEDULER_}"; RESOLVED_E2E_MAKE_ARGS+=("SHARDING_MODE=${suffix,,}")
      ;;
    SCHEDULERSHARDING) RESOLVED_E2E_TARGET=e2e-test-schedulersharding ;;
    SCHEDULERSHARDING_NONE|SCHEDULERSHARDING_SOFT|SCHEDULERSHARDING_HARD)
      RESOLVED_E2E_TARGET=e2e-test-schedulersharding
      suffix="${type#SCHEDULERSHARDING_}"; RESOLVED_E2E_MAKE_ARGS+=("SHARDING_MODE=${suffix,,}")
      ;;
    *)
      suffix="$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
      RESOLVED_E2E_TARGET="e2e-test-$suffix"
      ;;
  esac
}

find_candidate_make_target() {
  awk -v target="$1" '
    /^\t/ || /^[[:space:]]*#/ {next}
    {
      line=$0; sub(/^[[:space:]]+/, "", line)
      colon=index(line, ":"); if (!colon) next
      count=split(substr(line, 1, colon-1), names, /[[:space:]]+/)
      for (i=1; i<=count; i++) if (names[i]==target) {print line; exit}
    }
  ' "$CHECKOUT/Makefile"
}

add_e2e_contract_key() {
  local key="$1" existing
  for existing in "${E2E_CONTRACT_KEYS[@]}"; do [[ "$existing" != "$key" ]] || return 0; done
  E2E_CONTRACT_KEYS+=("$key")
}

resolve_candidate_e2e_contract() {
  local type="$1" target_line rhs item dry_run runner prefix make_capture prefix_capture make_helper
  local assignment key value file source
  local -a runner_lines=() prerequisites=() environment_keys=()
  local -A environment=()
  RESOLVED_E2E_ERROR=""
  [[ "$type" =~ ^[A-Z][A-Z0-9_]*$ ]] || { RESOLVED_E2E_ERROR="invalid E2E type: $type"; return 11; }
  e2e_make_target_for_type "$type"
  target_line="$(find_candidate_make_target "$RESOLVED_E2E_TARGET")"
  if [[ -z "$target_line" ]]; then
    RESOLVED_E2E_ERROR="Candidate has no upstream Make target $RESOLVED_E2E_TARGET for E2E $type"
    return 10
  fi
  rhs="${target_line#*:}"; rhs="${rhs%%#*}"
  read -r -a prerequisites <<< "$rhs"
  dry_run="$WORK_DIR/e2e-contract-${type,,}.make-n"
  if ! (cd "$CHECKOUT"; make --no-print-directory -n "${RESOLVED_E2E_MAKE_ARGS[@]}" "$RESOLVED_E2E_TARGET") > "$dry_run" 2>&1; then
    cp -- "$dry_run" "$OUTPUT_DIR/candidate-e2e-contract-${type,,}-error.txt"
    RESOLVED_E2E_ERROR="cannot render $RESOLVED_E2E_TARGET; see candidate-e2e-contract-${type,,}-error.txt"
    return 11
  fi
  mapfile -t runner_lines < <(grep -E '(^|[[:space:]])(bash[[:space:]]+)?(\./)?hack/run-e2e-kind\.sh[[:space:]]*$' "$dry_run" || true)
  rm -f -- "$dry_run"
  if [[ ${#runner_lines[@]} -ne 1 ]]; then
    RESOLVED_E2E_ERROR="expected one upstream run-e2e-kind.sh recipe for $RESOLVED_E2E_TARGET, found ${#runner_lines[@]}"
    return 11
  fi
  runner="${runner_lines[0]}"
  runner="${runner#"${runner%%[![:space:]]*}"}"; runner="${runner%"${runner##*[![:space:]]}"}"
  case "$runner" in
    './hack/run-e2e-kind.sh'|'hack/run-e2e-kind.sh'|'bash ./hack/run-e2e-kind.sh'|'bash hack/run-e2e-kind.sh') prefix="" ;;
    *' bash ./hack/run-e2e-kind.sh') prefix="${runner% bash ./hack/run-e2e-kind.sh}" ;;
    *' bash hack/run-e2e-kind.sh') prefix="${runner% bash hack/run-e2e-kind.sh}" ;;
    *' ./hack/run-e2e-kind.sh') prefix="${runner% ./hack/run-e2e-kind.sh}" ;;
    *' hack/run-e2e-kind.sh') prefix="${runner% hack/run-e2e-kind.sh}" ;;
    *) RESOLVED_E2E_ERROR="unsupported upstream E2E recipe: $runner"; return 11 ;;
  esac
  make_capture="$WORK_DIR/e2e-contract-${type,,}.make-env"
  prefix_capture="$WORK_DIR/e2e-contract-${type,,}.recipe-env"
  make_helper="$WORK_DIR/e2e-contract-${type,,}.capture.mk"
  mkdir -p "$WORK_DIR/make-environment-home"
  printf '.PHONY: __vpg4_capture_make_environment\n__vpg4_capture_make_environment:\n\t@env -0\n' > "$make_helper"
  # The upstream runner is normally launched by Make. Capture the variables
  # exported by the Candidate Makefile in an empty environment, then overlay
  # the recipe's leading assignments. This preserves generic build-output
  # contracts such as BIN_DIR without inheriting host credentials or proxies.
  if ! (cd "$CHECKOUT"; env -i PATH="$PATH" HOME="$WORK_DIR/make-environment-home" \
      GOROOT="$GOROOT" GOPATH="$GOPATH" GOMODCACHE="$GOMODCACHE" GOCACHE="$GOCACHE" GOTOOLCHAIN=local \
      make --no-print-directory -s \
      -f "$CHECKOUT/Makefile" -f "$make_helper" "${RESOLVED_E2E_MAKE_ARGS[@]}" \
      __vpg4_capture_make_environment) > "$make_capture"; then
    rm -f -- "$make_capture" "$prefix_capture" "$make_helper"
    RESOLVED_E2E_ERROR="cannot capture Candidate Make environment for $RESOLVED_E2E_TARGET"
    return 11
  fi
  if ! (cd "$CHECKOUT"; env -i PATH=/usr/bin:/bin bash -c "${prefix:+$prefix }env -0") > "$prefix_capture"; then
    rm -f -- "$make_capture" "$prefix_capture" "$make_helper"
    RESOLVED_E2E_ERROR="cannot evaluate upstream E2E assignments for $RESOLVED_E2E_TARGET"
    return 11
  fi
  for source in "$make_capture" "$prefix_capture"; do
    while IFS= read -r -d '' assignment; do
      [[ "$assignment" == *=* ]] || {
        rm -f -- "$make_capture" "$prefix_capture" "$make_helper"
        RESOLVED_E2E_ERROR="invalid output while capturing Candidate E2E environment"
        return 11
      }
      key="${assignment%%=*}"; value="${assignment#*=}"
      case "$key" in
        PWD|OLDPWD|SHLVL|PATH|_|MAKEFLAGS|MFLAGS|MAKELEVEL|MAKEOVERRIDES|MAKE_TERMOUT|MAKE_TERMERR|GNUMAKEFLAGS) continue ;;
      esac
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        rm -f -- "$make_capture" "$prefix_capture" "$make_helper"
        RESOLVED_E2E_ERROR="invalid upstream E2E environment assignment: $key"
        return 11
      fi
      if [[ "$value" == *$'\t'* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        # .EXPORT_ALL_VARIABLES also exposes multiline Make functions. They
        # are not process settings and cannot be represented by the TSV
        # contract. A multiline recipe assignment, however, is ambiguous and
        # must still fail closed.
        if [[ "$source" == "$make_capture" ]]; then continue; fi
        rm -f -- "$make_capture" "$prefix_capture" "$make_helper"
        RESOLVED_E2E_ERROR="invalid multiline upstream E2E environment assignment: $key"
        return 11
      fi
      case "$key" in
        VPG_*|CLUSTER_NAME|CLEANUP_CLUSTER|KIND_OPT|IMAGE_PREFIX|TAG|OS|ARTIFACTS_PATH|KUBECONFIG|SKIP_CLUSTER_SETUP|HOME|GOROOT|GOPATH|GOMODCACHE|GOCACHE|GOPROXY|GONOSUMDB|GOSUMDB|GOTOOLCHAIN|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy)
          if [[ "$source" == "$make_capture" ]]; then continue; fi
          rm -f -- "$make_capture" "$prefix_capture" "$make_helper"
          RESOLVED_E2E_ERROR="upstream E2E contract attempts to override managed variable $key"
          return 11
          ;;
      esac
      if [[ -z "${environment[$key]+defined}" ]]; then environment_keys+=("$key"); fi
      environment[$key]="$value"
    done < "$source"
  done
  rm -f -- "$make_capture" "$prefix_capture" "$make_helper"
  if [[ -n "${environment[E2E_TYPE]+defined}" ]]; then
    [[ "${environment[E2E_TYPE]}" == "$type" ]] || {
      RESOLVED_E2E_ERROR="$RESOLVED_E2E_TARGET resolves E2E_TYPE=${environment[E2E_TYPE]}, expected $type"
      return 11
    }
  else
    environment_keys+=(E2E_TYPE); environment[E2E_TYPE]="$type"
  fi
  file="$(e2e_contract_path "$type")" || { RESOLVED_E2E_ERROR="invalid E2E contract path"; return 11; }
  : > "$file"; printf 'TARGET\t%s\n' "$RESOLVED_E2E_TARGET" >> "$file"
  for item in "${RESOLVED_E2E_MAKE_ARGS[@]}"; do printf 'MAKE_ARG\t%s\n' "$item" >> "$file"; done
  for item in "${prerequisites[@]}"; do
    case "$item" in ''|images|'|') continue ;; esac
    [[ "$item" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
      RESOLVED_E2E_ERROR="unsupported prerequisite '$item' on $RESOLVED_E2E_TARGET"; return 11; }
    printf 'PREREQ\t%s\n' "$item" >> "$file"
  done
  for key in "${environment_keys[@]}"; do
    printf 'ENV\t%s\t%s\n' "$key" "${environment[$key]}" >> "$file"
    add_e2e_contract_key "$key"
  done
}

prepare_candidate_e2e_contracts() {
  local type status file record key value
  local -a runnable=()
  mkdir -p "$E2E_CONTRACT_DIR"; : > "$E2E_CONTRACT_REPORT"
  for type in "${E2E_RUNS[@]}"; do
    if resolve_candidate_e2e_contract "$type"; then
      :
    else
      status=$?
      if [[ "$status" -eq 10 && "$E2E_SELECTION" == FULL ]]; then
        log "Candidate does not define E2E $type; skipping this profile entry"
        printf 'type=%s\nstatus=not-defined-by-candidate\nreason=%s\n\n' "$type" "$RESOLVED_E2E_ERROR" >> "$E2E_CONTRACT_REPORT"
        continue
      fi
      die "$RESOLVED_E2E_ERROR"
    fi
    runnable+=("$type"); file="$(e2e_contract_path "$type")"
    printf 'type=%s\n' "$type" >> "$E2E_CONTRACT_REPORT"
    while IFS=$'\t' read -r record key value; do
      case "$record" in
        TARGET) printf 'target=%s\n' "$key" ;;
        MAKE_ARG) printf 'make_arg=%s\n' "$key" ;;
        PREREQ) printf 'prerequisite=%s\n' "$key" ;;
        ENV) printf 'env.%s=%s\n' "$key" "$value" ;;
      esac
    done < "$file" >> "$E2E_CONTRACT_REPORT"
    printf '\n' >> "$E2E_CONTRACT_REPORT"
    log "resolved upstream E2E contract: $type -> $RESOLVED_E2E_TARGET"
  done
  E2E_RUNS=("${runnable[@]}")
  [[ ${#E2E_RUNS[@]} -gt 0 ]] || die "Candidate exposes none of the E2E entries selected by profile $PROFILE"
}

e2e_contract_value() {
  local file
  file="$(e2e_contract_path "$1")" || return 1
  awk -F '\t' -v key="$2" '$1=="ENV" && $2==key {print $3; exit}' "$file"
}

load_e2e_contract_environment() {
  local file record key value
  file="$(e2e_contract_path "$1")" || die "invalid E2E contract path: $1"
  for key in "${E2E_CONTRACT_KEYS[@]}"; do unset "$key" || true; done
  while IFS=$'\t' read -r record key value; do
    [[ "$record" != ENV ]] || export "$key=$value"
  done < "$file"
}

candidate_default_e2e_release_name() {
  awk '
    {
      line=$0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*(export[[:space:]]+)?CLUSTER_NAME=\$\{CLUSTER_NAME:-[^}]+\}[[:space:]]*$/) {
        sub(/^[[:space:]]*(export[[:space:]]+)?CLUSTER_NAME=\$\{CLUSTER_NAME:-/, "", line)
        sub(/\}[[:space:]]*$/, "", line)
        sub(/^["\047]/, "", line)
        sub(/["\047]$/, "", line)
        print line
        exit
      }
    }
  ' "$CHECKOUT/hack/run-e2e-kind.sh"
}

build_e2e_contract_prerequisites() {
  local file record value extra
  local -a make_args=() prerequisites=()
  file="$(e2e_contract_path "$1")" || die "invalid E2E contract path: $1"
  while IFS=$'\t' read -r record value extra; do
    case "$record" in MAKE_ARG) make_args+=("$value") ;; PREREQ) prerequisites+=("$value") ;; esac
  done < "$file"
  [[ ${#prerequisites[@]} -gt 0 ]] || return 0
  log "building upstream E2E prerequisites for $1: ${prerequisites[*]}"
  (cd "$CHECKOUT"; make "${make_args[@]}" "${prerequisites[@]}") 2>&1 | tee -a "$2/prerequisites.log"
}
E2E_SELECTION="${E2E_TYPE_OVERRIDE:-$DEFAULT_RUN}"
BENCHMARK_SELECTION="${BENCHMARK_SCENARIO_OVERRIDE:-$DEFAULT_RUN}"
if [[ "$MODE" == both ]]; then
  [[ -n "$E2E_TYPE_OVERRIDE" ]] || E2E_SELECTION=FULL
  [[ -n "$BENCHMARK_SCENARIO_OVERRIDE" ]] || BENCHMARK_SELECTION=FULL
fi
if [[ "$MANUAL_ACTION" == deploy-only ]]; then
  E2E_RUNS=()
elif [[ "$MODE" != benchmark ]]; then
  if [[ "$E2E_SELECTION" == FULL ]]; then E2E_RUNS=("${E2E_CAPS[@]}")
  else
    found=false; for value in "${E2E_CAPS[@]}"; do [[ "$value" != "$E2E_SELECTION" ]] || found=true; done
    [[ "$found" == true ]] || die "E2E type $E2E_SELECTION is not covered by profile $PROFILE"
    E2E_RUNS=("$E2E_SELECTION")
  fi
else E2E_RUNS=(); fi

if [[ ${#E2E_RUNS[@]} -gt 0 ]]; then prepare_candidate_e2e_contracts; fi

E2E_HELM_RELEASE_NAME=""
if [[ ${#E2E_RUNS[@]} -gt 0 ]]; then
  E2E_HELM_RELEASE_NAME="$(candidate_default_e2e_release_name)"
  [[ ${#E2E_HELM_RELEASE_NAME} -le 53 && "$E2E_HELM_RELEASE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
    die "cannot resolve the Candidate's default E2E Helm release name"
  log "using Candidate-default E2E Helm release: $E2E_HELM_RELEASE_NAME"
fi

if (( K8S_MINOR < 34 && ${#E2E_RUNS[@]} > 0 )); then
  for value in "${E2E_RUNS[@]}"; do
    case "$value" in
      ALL|DRA)
        feature_gates="$(e2e_contract_value "$value" FEATURE_GATES || true)"
        if [[ "$feature_gates" == *DRAConsumableCapacity=true* ]] || \
          grep -q 'DRAConsumableCapacity' "$CHECKOUT/hack/e2e-kind-config.yaml"; then
          die "Candidate E2E $value requires Kubernetes v1.34+ because its upstream contract enables DRAConsumableCapacity"
        fi
        ;;
    esac
  done
fi

BENCHMARK_RUN_SCENARIOS=(); BENCHMARK_RUN_CONFIGS=()
if [[ "$MANUAL_ACTION" == deploy-only ]]; then
  BENCHMARK_RUN_SCENARIOS=(); BENCHMARK_RUN_CONFIGS=()
elif [[ "$MODE" != e2e ]]; then
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
[[ -n "$MANUAL_ACTION" || "$KEEP_CLUSTER" != true || $(( ${#E2E_RUNS[@]} + ${#BENCHMARK_RUN_SCENARIOS[@]} )) -eq 1 ]] || \
  die "--keep-cluster requires exactly one run"

# Volcano imports parts of the Kubernetes E2E framework. Some runtime images
# are therefore selected by k8s.io/kubernetes rather than by Volcano source
# literals. Resolve those exact references from the already-downloaded module
# and fail before Kind creation if the generic bundle is incomplete.
if [[ ${#E2E_RUNS[@]} -gt 0 ]]; then
  CANDIDATE_K8S_MODULE="$(awk '$1=="k8s.io/kubernetes" {print $2;exit}' "$CHECKOUT/go.mod")"
  [[ "$CANDIDATE_K8S_MODULE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "cannot resolve Candidate k8s.io/kubernetes version"
  K8S_E2E_MODULE_DIR="$GOMODCACHE/k8s.io/kubernetes@$CANDIDATE_K8S_MODULE"
  K8S_IMAGE_MANIFEST="$K8S_E2E_MODULE_DIR/test/utils/image/manifest.go"
  [[ -f "$K8S_IMAGE_MANIFEST" ]] || die "downloaded Kubernetes E2E image manifest is missing: $K8S_IMAGE_MANIFEST"
  K8S_E2E_REGISTRY="$(awk -F'"' '/PromoterE2eRegistry:[[:space:]]*"/ {print $2;exit}' "$K8S_IMAGE_MANIFEST")"
  K8S_AGNHOST_VERSION="$(awk -F'"' '/configs\[Agnhost\][[:space:]]*=/ {print $4;exit}' "$K8S_IMAGE_MANIFEST")"
  K8S_BUSYBOX_VERSION="$(awk -F'"' '/configs\[BusyBox\][[:space:]]*=/ {print $4;exit}' "$K8S_IMAGE_MANIFEST")"
  K8S_NGINX_VERSION="$(awk -F'"' '/configs\[Nginx\][[:space:]]*=/ {print $4;exit}' "$K8S_IMAGE_MANIFEST")"
  [[ -n "$K8S_E2E_REGISTRY" && -n "$K8S_AGNHOST_VERSION" && -n "$K8S_BUSYBOX_VERSION" && -n "$K8S_NGINX_VERSION" ]] || \
    die "cannot resolve Kubernetes E2E runtime images from $K8S_IMAGE_MANIFEST"
  REQUIRED_CANDIDATE_E2E_IMAGES=(
    "$K8S_E2E_REGISTRY/agnhost:$K8S_AGNHOST_VERSION"
    "$K8S_E2E_REGISTRY/busybox:$K8S_BUSYBOX_VERSION"
    "$K8S_E2E_REGISTRY/nginx:$K8S_NGINX_VERSION"
  )
  NEED_DRA_IMAGE=false
  for value in "${E2E_RUNS[@]}"; do
    [[ "$value" != ALL && "$value" != DRA ]] || NEED_DRA_IMAGE=true
  done
  if [[ "$NEED_DRA_IMAGE" == true ]]; then
    K8S_DRA_MANIFEST="$K8S_E2E_MODULE_DIR/test/e2e/testing-manifests/dra/dra-test-driver-proxy.yaml"
    [[ -f "$K8S_DRA_MANIFEST" ]] || die "Candidate DRA runtime manifest is missing: $K8S_DRA_MANIFEST"
    mapfile -t K8S_DRA_IMAGES < <(awk '$1=="image:" && $2 ~ /hostpathplugin:/ {print $2}' "$K8S_DRA_MANIFEST" | sort -u)
    [[ ${#K8S_DRA_IMAGES[@]} -gt 0 ]] || die "cannot resolve Candidate DRA runtime image"
    REQUIRED_CANDIDATE_E2E_IMAGES+=("${K8S_DRA_IMAGES[@]}")
  fi
  printf '%s\n' "${REQUIRED_CANDIDATE_E2E_IMAGES[@]}" > "$OUTPUT_DIR/candidate-e2e-images.txt"
  for value in "${REQUIRED_CANDIDATE_E2E_IMAGES[@]}"; do
    bundle_has_image_ref "$value" || die "Candidate E2E runtime image is not bundled: $value; update config/profiles.tsv or package with --add-image $value"
    docker image inspect "${value%@*}" >/dev/null 2>&1 || die "Candidate E2E runtime image was not loaded: $value"
  done
  log "verified Candidate-selected Kubernetes E2E runtime images"

fi

# Local image reuse requires the Docker buildx driver; docker-container cannot
# see the imported bases without a registry.
docker buildx inspect default >/dev/null 2>&1 || die "Docker default buildx builder is unavailable"
driver="$(docker buildx inspect default | awk -F': ' '/^Driver:/ && !found {print $2;found=1}' | tr -d '[:space:]')"
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

patch_candidate_build_network() {
  local makefile="$CHECKOUT/Makefile" dockerignore="$CHECKOUT/.dockerignore"
  local webhook_dockerfile="$CHECKOUT/installer/dockerfile/webhook-manager/Dockerfile"
  local webhook_script="$CHECKOUT/installer/dockerfile/webhook-manager/gen-admission-secret.sh"
  local tmp="$WORK_DIR/patch.tmp" name rel path runtime_base runtime_ref
  local need_goproxy need_gonosumdb need_gosumdb
  local -a patched=(Makefile)
  [[ -f "$makefile" ]] || die "Candidate Makefile is missing"
  [[ -f "$webhook_dockerfile" && -f "$webhook_script" ]] || die "Candidate webhook runtime files are missing"
  cp -- "$BIN_DIR/kubectl" "$CHECKOUT/.vpg4-kubectl"
  cp -- "$VPG_INNER_GO_MODULE_ARCHIVE" "$CHECKOUT/.vpg4-inner-go-modules.tar.gz"
  chmod 0755 "$CHECKOUT/.vpg4-kubectl"
  printf '\n!.vpg4-kubectl\n!.vpg4-inner-go-modules.tar.gz\n' >> "$dockerignore"
  patched+=(.dockerignore installer/dockerfile/webhook-manager/gen-admission-secret.sh)
  awk '
    BEGIN {inserted=0}
    {
      print
      if ($0 ~ /--platform[[:space:]]+/ && $0 ~ /DOCKER_PLATFORMS/) {
        print "\t\t\t--build-arg GOPROXY \\"
        print "\t\t\t--build-arg GONOSUMDB \\"
        print "\t\t\t--build-arg GOSUMDB \\"
        print "\t\t\t--build-arg HTTP_PROXY \\"
        print "\t\t\t--build-arg HTTPS_PROXY \\"
        print "\t\t\t--build-arg NO_PROXY \\"
        print "\t\t\t--network host \\"
        inserted++
      }
    }
    END {if(inserted<1) exit 44}
  ' "$makefile" > "$tmp" || die "cannot add Candidate BuildKit network settings"
  mv "$tmp" "$makefile"

  for name in "${DOCKERFILES[@]}"; do
    if [[ "$name" == benchmark-audit-exporter ]]; then rel="benchmark/manifests/audit-exporter/Dockerfile"
    else rel="installer/dockerfile/$name/Dockerfile"; fi
    path="$CHECKOUT/$rel"; patched+=("$rel")
    [[ -f "$path" ]] || die "Candidate Dockerfile missing: $path"
    grep -Eq '^[[:space:]]*RUN[[:space:]]+go[[:space:]]+mod[[:space:]]+download' "$path" || continue
    need_goproxy=true; need_gonosumdb=true; need_gosumdb=true
    grep -Eq '^[[:space:]]*ARG[[:space:]]+GOPROXY([[:space:]=]|$)' "$path" && need_goproxy=false
    grep -Eq '^[[:space:]]*ARG[[:space:]]+GONOSUMDB([[:space:]=]|$)' "$path" && need_gonosumdb=false
    grep -Eq '^[[:space:]]*ARG[[:space:]]+GOSUMDB([[:space:]=]|$)' "$path" && need_gosumdb=false
    awk -v need_gp="$need_goproxy" -v need_gn="$need_gonosumdb" -v need_gs="$need_gosumdb" '
      BEGIN {inserted=0; replaced=0}
      {
        upper=toupper($0)
        if ($0 ~ /^[[:space:]]*RUN[[:space:]]+go[[:space:]]+mod[[:space:]]+download/) {
          command=$0
          sub(/^[[:space:]]*RUN[[:space:]]+/, "", command)
          sub(/\r$/, "", command)
          print "COPY .vpg4-inner-go-modules.tar.gz /tmp/vpg4-inner-go-modules.tar.gz"
          print "RUN mkdir -p /tmp/vpg4-goproxy \\"
          print "    && tar -xzf /tmp/vpg4-inner-go-modules.tar.gz -C /tmp/vpg4-goproxy \\"
          print "    && GOPROXY=file:///tmp/vpg4-goproxy GONOSUMDB=* GOSUMDB=off " command " \\"
          print "    && rm -rf /tmp/vpg4-goproxy /tmp/vpg4-inner-go-modules.tar.gz"
          replaced++
          next
        }
        print
        if (!inserted && upper ~ /^[[:space:]]*FROM[[:space:]].*[[:space:]]AS[[:space:]]+BUILDER([[:space:]]|$)/) {
          if (need_gp=="true") print "ARG GOPROXY"
          if (need_gn=="true") print "ARG GONOSUMDB"
          if (need_gs=="true") print "ARG GOSUMDB"
          inserted=1
        }
      }
      END {if(inserted!=1 || replaced!=1) exit 45}
    ' "$path" > "$tmp" || die "cannot add Go proxy arguments to Candidate Dockerfile: $rel"
    mv "$tmp" "$path"
  done

  if grep -q 'https://dl.k8s.io/' "$webhook_dockerfile" || grep -Eq '^[[:space:]]*apk[[:space:]]+add|&&[[:space:]]*apk[[:space:]]+add' "$webhook_dockerfile"; then
    runtime_base="$(awk 'toupper($1)=="FROM" {for(i=2;i<=NF;i++) if($i!~/^--/){gsub(/\r/,"",$i);print $i;exit}}' "$webhook_dockerfile")"
    [[ -n "$runtime_base" && "$runtime_base" != *'${'* ]] || die "cannot resolve Candidate webhook builder base"
    runtime_ref="${runtime_base%@*}"
    bundle_has_image_ref "$runtime_base" || die "Candidate webhook offline runtime base is not bundled: $runtime_base"
    docker image inspect "$runtime_ref" >/dev/null 2>&1 || die "Candidate webhook offline runtime base is not bundled: $runtime_base"
    docker run --rm --entrypoint /bin/sh "$runtime_ref" -ec \
      'test -x /bin/bash && command -v openssl >/dev/null && test -f /etc/ssl/certs/ca-certificates.crt && command -v base64 >/dev/null && command -v tr >/dev/null' \
      || die "Candidate webhook builder base lacks Bash, OpenSSL, CA certificates or core tools"
    log "replacing Candidate webhook APK and kubectl downloads with packaged runtime inputs"
    awk -v runtime_base="$runtime_base" '
      BEGIN {stage=0; replaced_from=0; removed_network=0; inserted_kubectl=0; skip=0}
      {
        upper=toupper($1)
        if (upper=="FROM") {
          stage++
          if (stage==2) {print "FROM " runtime_base; print "WORKDIR /"; replaced_from++; next}
        }
        if (stage==2 && $1=="ARG" && ($2 ~ /^KUBE_VERSION([=]|$)/ || $2=="TARGETARCH" || $2=="APK_MIRROR")) next
        if (stage==2 && !skip && $0 ~ /^[[:space:]]*RUN[[:space:]]+if[[:space:]]+\[\[/) {
          skip=1; removed_network++
          if ($0 !~ /\\[[:space:]]*$/) skip=0
          next
        }
        if (skip) {
          if ($0 !~ /\\[[:space:]]*$/) skip=0
          next
        }
        if (stage==2 && !inserted_kubectl && $0 ~ /^[[:space:]]*COPY[[:space:]]+--from=builder/) {
          print "COPY .vpg4-kubectl /usr/local/bin/kubectl"
          inserted_kubectl++
        }
        print
      }
      END {
        if (stage<2 || replaced_from!=1 || removed_network!=1 || inserted_kubectl!=1 || skip) exit 47
      }
    ' "$webhook_dockerfile" > "$tmp" || die "cannot make Candidate webhook runtime offline"
    mv "$tmp" "$webhook_dockerfile"
    grep -q '^#!/bin/sh$' "$webhook_script" || die "unexpected Candidate admission helper shell"
    sed -i '1s|^#!/bin/sh$|#!/bin/bash|' "$webhook_script"
  fi
  grep -q 'https://dl.k8s.io/' "$webhook_dockerfile" && die "Candidate webhook still downloads kubectl"
  grep -Eq '^[[:space:]]*apk[[:space:]]+add|&&[[:space:]]*apk[[:space:]]+add' "$webhook_dockerfile" && die "Candidate webhook still downloads APK packages"
  git -C "$CHECKOUT" diff -- "${patched[@]}" > "$OUTPUT_DIR/candidate-build-network.patch"
  [[ -s "$OUTPUT_DIR/candidate-build-network.patch" ]] || die "Candidate build network patch is empty"
}

if stage_done candidate-build-patch; then
  [[ -s "$OUTPUT_DIR/candidate-build-network.patch" ]] || die "saved Candidate build patch evidence is missing"
  log "reusing the patched Candidate Docker build environment"
else
  git -C "$CHECKOUT" status --short > "$OUTPUT_DIR/candidate-status-before-build-patch.txt"
  if [[ -s "$OUTPUT_DIR/candidate-status-before-build-patch.txt" ]]; then
    log "Candidate checkout contains generated or local changes; continuing with verified commit $CANDIDATE_COMMIT"
  fi
  patch_candidate_build_network
  mark_stage candidate-build-patch
fi

# Builds created by older deploy scripts may have saved a CR from a CRLF
# Dockerfile immediately before the generated continuation backslash. Repair
# those resumable work directories in place; the fixed patcher above prevents
# the malformed command in new work directories.
repair_legacy_candidate_go_download_cr() {
  local name rel path tmp repaired=false
  local -a evidence_paths=(
    Makefile
    .dockerignore
    installer/dockerfile/webhook-manager/gen-admission-secret.sh
  )
  for name in "${DOCKERFILES[@]}"; do
    if [[ "$name" == benchmark-audit-exporter ]]; then rel="benchmark/manifests/audit-exporter/Dockerfile"
    else rel="installer/dockerfile/$name/Dockerfile"; fi
    path="$CHECKOUT/$rel"; evidence_paths+=("$rel")
    if LC_ALL=C grep -Fq $'\r \\' "$path"; then
      tmp="$WORK_DIR/repair-${name}-dockerfile.tmp"
      tr -d '\r' < "$path" > "$tmp" || die "cannot repair CRLF Candidate Dockerfile: $rel"
      mv "$tmp" "$path"
      repaired=true
    fi
  done
  if [[ "$repaired" == true ]]; then
    git -C "$CHECKOUT" diff -- "${evidence_paths[@]}" > "$OUTPUT_DIR/candidate-build-network.patch"
    [[ -s "$OUTPUT_DIR/candidate-build-network.patch" ]] || die "repaired Candidate build patch evidence is empty"
    log "repaired CRLF contamination in the saved Candidate Docker build patch"
  fi
}
repair_legacy_candidate_go_download_cr

for name in "${DOCKERFILES[@]}"; do
  if [[ "$name" == benchmark-audit-exporter ]]; then path="$CHECKOUT/benchmark/manifests/audit-exporter/Dockerfile"
  else path="$CHECKOUT/installer/dockerfile/$name/Dockerfile"; fi
  [[ -f "$path" ]] || die "Candidate Dockerfile missing: $path"
  while IFS= read -r base; do
    [[ "$base" != *'${'* ]] || die "unresolved Candidate base in $path: $base"
    bundle_has_image_ref "$base" || die "Candidate base is not declared by this generic bundle: $base; add it to config/profiles.tsv or use --add-image when packaging"
    docker image inspect "${base%@*}" >/dev/null 2>&1 || die "Candidate base is not bundled: $base; repack for this Candidate"
  # Keep the inner preflight identical to the packager for CRLF Dockerfiles.
  done < <(awk 'toupper($1)=="FROM" {for(i=2;i<=NF;i++) if($i!~/^--/){gsub(/\r/,"",$i);print $i;break}}' "$path" | sort -u)
done

BUILD_TARGETS=(vc-scheduler-image vc-controller-manager-image vc-webhook-manager-image)
[[ "$BUILD_AGENT" != true ]] || BUILD_TARGETS+=(vc-agent-scheduler-image)
CANDIDATE_IMAGES=("volcanosh/vc-scheduler:$CANDIDATE_COMMIT" "volcanosh/vc-controller-manager:$CANDIDATE_COMMIT" "volcanosh/vc-webhook-manager:$CANDIDATE_COMMIT")
[[ "$BUILD_AGENT" != true ]] || CANDIDATE_IMAGES+=("volcanosh/vc-agent-scheduler:$CANDIDATE_COMMIT")
candidate_images_available() {
  local image
  for image in "${CANDIDATE_IMAGES[@]}"; do
    [[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image" 2>/dev/null)" == linux/amd64 ]] || return 1
  done
}
if stage_done candidate-images && candidate_images_available; then
  log "reusing previously built Candidate images at $CANDIDATE_COMMIT"
else
  log "building Candidate images at $CANDIDATE_COMMIT"
  (
    cd "$CHECKOUT"
    # Every Dockerfile receives the verified inner-host file proxy for its
    # explicit go mod download. Disable all later Go network fallback so an
    # incomplete prefetch fails closed instead of contacting HTTPS from Docker.
    export GOPROXY=off GONOSUMDB='*' GOSUMDB=off
    make "${BUILD_TARGETS[@]}" "TAG=$CANDIDATE_COMMIT" IMAGE_PREFIX=volcanosh FORCE_REBUILD=true \
      BUILDX_OUTPUT_TYPE=docker DOCKER_PLATFORMS=linux/amd64
  ) 2>&1 | tee -a "$OUTPUT_DIR/candidate-build.log"
  candidate_images_available || die "one or more Candidate images were not built for linux/amd64"
  mark_stage candidate-images
fi
for image in "${CANDIDATE_IMAGES[@]}"; do
  [[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" == linux/amd64 ]] || die "Candidate image platform mismatch: $image"
done

cluster_name() {
  local purpose="$1" index="$2" name suffix max_base
  # Keep generated Kind names compact and stable while preserving the per-run
  # index used by saved-work identity checks.
  suffix="-$index"
  max_base=$((27 - ${#suffix}))
  name="${CLUSTER_PREFIX}-${CANDIDATE_COMMIT:0:8}-${purpose}-${index}"
  name="${name%$suffix}"
  name="${name:0:max_base}${suffix}"
  printf '%s\n' "${name%-}"
}
record_cluster_identity() {
  local kubeconfig="$1" purpose="$2"
  kubectl --kubeconfig "$kubeconfig" -n kube-system create configmap vpg4-resume-state \
    --from-literal="run-id=$RUN_ID" --from-literal="candidate-commit=$CANDIDATE_COMMIT" \
    --from-literal="purpose=$purpose" --dry-run=client -o yaml | \
    kubectl --kubeconfig "$kubeconfig" apply -f - >/dev/null
}
validate_saved_cluster() {
  local name="$1" purpose="$2" kubeconfig="$3" release="$4" observed identity
  [[ "$RESUME_WORK" == true && "$KEEP_CLUSTER" == true ]] || die "cluster already exists: $name; resume it with the saved --work-dir and --keep-cluster"
  [[ "$(state_get ACTIVE_CLUSTER)" == "$name" && "$(state_get ACTIVE_PURPOSE)" == "$purpose" ]] || \
    die "saved active-cluster identity does not match $name"
  kind get kubeconfig --name "$name" > "$kubeconfig"
  chmod 0600 "$kubeconfig"
  observed="$(kubectl --kubeconfig "$kubeconfig" version -o json | jq -r '.serverVersion.gitVersion')"
  [[ "$observed" == "$K8S_VERSION" ]] || die "saved cluster Kubernetes mismatch: expected $K8S_VERSION, got $observed"
  identity="$(kubectl --kubeconfig "$kubeconfig" -n kube-system get configmap vpg4-resume-state -o json)" || \
    die "saved cluster has no v4 resume identity: $name"
  jq -e --arg run "$RUN_ID" --arg commit "$CANDIDATE_COMMIT" --arg purpose "$purpose" \
    '.data["run-id"]==$run and .data["candidate-commit"]==$commit and .data.purpose==$purpose' \
    <<< "$identity" >/dev/null || die "saved cluster identity does not match this run"
  if [[ -n "$release" ]]; then
    helm status "$release" -n volcano-system --kubeconfig "$kubeconfig" -o json | \
      jq -e '.info.status=="deployed"' >/dev/null || die "saved cluster Helm release is not deployed: $release"
    helm get values "$release" -n volcano-system --kubeconfig "$kubeconfig" --all -o json | \
      jq -e --arg commit "$CANDIDATE_COMMIT" '.basic.image_tag_version==$commit' >/dev/null || \
      die "saved cluster Helm release uses a different Candidate: $release"
  fi
  log "validated and reusing saved Kind cluster: $name"
}
delete_cluster() {
  local purpose="$1" delete_status=0
  if [[ "$KEEP_CLUSTER" == true ]]; then log "keeping cluster: $CURRENT_CLUSTER"; return; fi
  if cluster_exists "$CURRENT_CLUSTER"; then
    set +e
    kind delete cluster --name "$CURRENT_CLUSTER" 2>&1 | tee "$OUTPUT_DIR/kind-delete-${purpose}.log"
    delete_status=$?
    set -e
    [[ "$delete_status" -eq 0 ]] || log "WARNING: failed to completely delete cluster $CURRENT_CLUSTER; continuing after batch cleanup"
  fi
  state_set ACTIVE_CLUSTER ""; state_set ACTIVE_PURPOSE ""
  CLUSTER_CREATED=false; CURRENT_CLUSTER=""
}
docker_save_archive() {
  local archive="$1" image
  shift
  [[ $# -gt 0 ]] || die "cannot save an empty image list"
  for image in "$@"; do
    [[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" == linux/amd64 ]] || \
      die "image platform mismatch before save: $image"
  done
  if docker image save --help 2>&1 | grep -q -- '--platform'; then
    docker image save --platform=linux/amd64 -o "$archive" "$@"
  else
    log "Docker image save has no --platform flag; using the validated linux/amd64 compatibility path"
    docker image save -o "$archive" "$@"
  fi
}
load_image_list() {
  local name="$1" file="$2" archive image
  local -a images=()
  archive="$WORK_DIR/kind-images-$name.tar"
  while IFS= read -r image; do [[ -z "$image" ]] || images+=("$image"); done < "$file"
  [[ ${#images[@]} -gt 0 ]] || die "runtime image list is empty: $file"
  docker_save_archive "$archive" "${images[@]}"
  kind load image-archive "$archive" --name "$name"
}
write_runtime_images() {
  local purpose="$1" output="$2" i key ref
  : > "$output"
  for ((i=0;i<${#IMAGE_KEYS[@]};i++)); do
    key="${IMAGE_KEYS[$i]}"; ref="${IMAGE_SAVE_REFS[$i]}"
    case "$key" in
      kind-node|candidate-*) ;;
      extra-*) printf '%s\n' "$ref" >> "$output" ;;
      busybox-*|nginx-*|k8s-e2e-*)
        [[ "$purpose" == e2e* ]] && printf '%s\n' "$ref" >> "$output" ;;
      kwok)
        [[ "$purpose" == e2e* || "$purpose" == benchmark* ]] && printf '%s\n' "$ref" >> "$output" ;;
      mpi|tensorflow|pytorch|ray*)
        [[ "$purpose" == e2e-ALL || "$purpose" == e2e-JOBSEQ ]] && printf '%s\n' "$ref" >> "$output" ;;
      dra-hostpath*)
        [[ "$purpose" == e2e-ALL || "$purpose" == e2e-DRA ]] && printf '%s\n' "$ref" >> "$output" ;;
      benchmark-busybox)
        [[ "$purpose" == benchmark* ]] && printf '%s\n' "$ref" >> "$output" ;;
      prometheus|grafana|kube-state-metrics)
        [[ "$purpose" == benchmark* ]] && printf '%s\n' "$ref" >> "$output" ;;
    esac
  done
  sort -u -o "$output" "$output"
}

patch_candidate_e2e_cluster_identity() {
  local runner="$CHECKOUT/hack/run-e2e-kind.sh" tmp="$WORK_DIR/patch-e2e-cluster.tmp"
  [[ -f "$runner" ]] || die "Candidate E2E runner is missing"
  if ! grep -Fq 'export CLUSTER_CONTEXT=("--name" "${CLUSTER_NAME}")' "$runner"; then
    grep -q 'VPG_KIND_CLUSTER_NAME' "$runner" || \
      die "Candidate E2E runner does not expose a supported Kind cluster identity contract"
    return 1
  fi
  awk '
    BEGIN {replaced=0}
    {
      if ($0 == "export CLUSTER_CONTEXT=(\"--name\" \"${CLUSTER_NAME}\")") {
        print "export CLUSTER_CONTEXT=(\"--name\" \"${VPG_KIND_CLUSTER_NAME:-${CLUSTER_NAME}}\")"
        replaced++
        next
      }
      print
    }
    END {if(replaced!=1) exit 50}
  ' "$runner" > "$tmp" || die "cannot decouple Candidate E2E Kind and Helm release names"
  mv "$tmp" "$runner"
  return 0
}

patch_candidate_e2e_local_image_tags() {
  local test_root="$CHECKOUT/test/e2e" util="$CHECKOUT/test/e2e/util/util.go" path
  local changed=false
  [[ -d "$test_root" ]] || return 1
  if [[ -f "$util" ]] && grep -Eq 'Default(BusyBox|Nginx)Image[[:space:]]*=[[:space:]]*"(busybox|nginx)"' "$util"; then
    sed -Ei \
      -e 's/(DefaultBusyBoxImage[[:space:]]*=[[:space:]]*)"busybox"/\1"busybox:1.24"/' \
      -e 's/(DefaultNginxImage[[:space:]]*=[[:space:]]*)"nginx"/\1"nginx:1.29.3-alpine"/' \
      "$util"
    changed=true
  fi
  while IFS= read -r path; do
    sed -Ei \
      -e 's/(Image:[[:space:]]*)"busybox"/\1"busybox:1.24"/g' \
      -e 's/(Image:[[:space:]]*)"nginx"/\1"nginx:1.29.3-alpine"/g' \
      "$path"
    changed=true
  done < <(grep -rlE --include='*.go' 'Image:[[:space:]]*"(busybox|nginx)"' "$test_root" || true)
  grep -REq --include='*.go' 'Image:[[:space:]]*"(busybox|nginx)"' "$test_root" && \
    die "Candidate E2E still uses an implicit latest runtime image"
  [[ ! -f "$util" ]] || ! grep -Eq 'Default(BusyBox|Nginx)Image[[:space:]]*=[[:space:]]*"(busybox|nginx)"' "$util" || \
    die "Candidate E2E still defines an implicit latest runtime image"
  [[ "$changed" == true ]]
}

patch_candidate_kwok_non_blocking() {
  local install="$CHECKOUT/hack/lib/install.sh" tmp="$WORK_DIR/patch-kwok-non-blocking.tmp" status
  [[ -f "$install" ]] || return 1
  grep -Fq 'VPG_KWOK_MANIFEST' "$install" || return 1
  if ! grep -Fq 'kubectl apply -f "${VPG_KWOK_MANIFEST:?}" || exit $?' "$install" && \
     ! grep -Fq 'kubectl apply -f "${VPG_KWOK_STAGE:?}" || exit $?' "$install" && \
     ! grep -Fq 'kubectl wait --for=condition=Available deployment/kwok-controller -n kube-system --timeout=120s || exit $?' "$install"; then
    return 1
  fi
  set +e
  awk '
    BEGIN {changed=0}
    {
      if ($0 == "  kubectl apply -f \"${VPG_KWOK_MANIFEST:?}\" || exit $?") {
        print "  kubectl apply -f \"${VPG_KWOK_MANIFEST:?}\""; changed++; next
      }
      if ($0 == "  kubectl apply -f \"${VPG_KWOK_STAGE:?}\" || exit $?") {
        print "  kubectl apply -f \"${VPG_KWOK_STAGE:?}\""; changed++; next
      }
      if ($0 == "  kubectl wait --for=condition=Available deployment/kwok-controller -n kube-system --timeout=120s || exit $?") {
        print "  kubectl wait --for=condition=Available deployment/kwok-controller -n kube-system --timeout=120s"; changed++; next
      }
      print
    }
    END {if(changed==0) exit 3; if(changed!=3) exit 4}
  ' "$install" > "$tmp"
  status=$?
  set -e
  case "$status" in
    0) mv "$tmp" "$install"; return 0 ;;
    3) rm -f -- "$tmp"; return 1 ;;
    *) rm -f -- "$tmp"; die "cannot restore Candidate KWOK non-blocking setup" ;;
  esac
}

patch_e2e_environment() {
  local install="$CHECKOUT/hack/lib/install.sh" runner="$CHECKOUT/hack/run-e2e-kind.sh"
  local kind_config="$CHECKOUT/hack/e2e-kind-config.yaml"
  local tmp="$WORK_DIR/patch.tmp"
  [[ -f "$install" && -f "$runner" && -f "$kind_config" ]] || die "Candidate E2E entrypoints are missing"
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
        print "  if [[ -n \"${VPG_RUNTIME_IMAGE_ARCHIVE:-}\" ]]; then"
        print "    echo \"Loading offline runtime images into Kind cluster ${CLUSTER_CONTEXT[1]}\""
        print "    kind load image-archive \"${VPG_RUNTIME_IMAGE_ARCHIVE}\" \"${CLUSTER_CONTEXT[@]}\""
        print "  fi"
        pending=0; inserted++
      }
    }
    END{if(inserted!=1) exit 43}
  ' "$install" > "$tmp" || die "cannot add offline image loading to Candidate Kind helper"
  mv "$tmp" "$install"
  if ! grep -q 'SKIP_CLUSTER_SETUP' "$runner"; then
    awk '
      BEGIN{wrapping=0; inserted=0}
      /^[[:space:]]*if[[:space:]]+\[\[[[:space:]]+\$CLEANUP_CLUSTER[[:space:]]+-eq[[:space:]]+1[[:space:]]+\]\];[[:space:]]+then[[:space:]]*$/ {
        print "if [[ \"${SKIP_CLUSTER_SETUP:-0}\" -eq 1 ]]; then"
        print "    echo \"Skipping cluster setup (SKIP_CLUSTER_SETUP=1), using existing cluster\""
        print "    source \"${VK_ROOT}/hack/lib/install.sh\""
        print "    check-prerequisites"
        print "else"
        wrapping=1
      }
      {print}
      wrapping && /^[[:space:]]*install-volcano[[:space:]]*$/ {
        print "fi"
        wrapping=0; inserted++
      }
      END{if(inserted!=1 || wrapping) exit 48}
    ' "$runner" > "$tmp" || die "cannot add saved-cluster setup bypass to Candidate E2E runner"
    mv "$tmp" "$runner"
  fi
  grep -q 'SKIP_CLUSTER_SETUP' "$runner" || die "Candidate E2E runner cannot reuse a saved cluster"
  awk '
    BEGIN{inserted=0}
    /^# Run e2e test/ {
      print "if [[ -n \"${VPG_RESUME_RUN_ID:-}\" ]]; then"
      print "  kubectl -n kube-system create configmap vpg4-resume-state --from-literal=run-id=\"${VPG_RESUME_RUN_ID}\" --from-literal=candidate-commit=\"${VPG_CANDIDATE_COMMIT:?}\" --from-literal=purpose=\"${VPG_RESUME_PURPOSE:?}\" --dry-run=client -o yaml | kubectl apply -f -"
      print "fi"
      print ""
      inserted++
    }
    {print}
    END{if(inserted!=1) exit 46}
  ' "$runner" > "$tmp" || die "cannot add E2E cluster resume identity"
  mv "$tmp" "$runner"
  if (( K8S_MINOR < 34 )) && grep -q 'DRAConsumableCapacity' "$kind_config"; then
    log "adapting the Candidate feature gates and API versions for Kubernetes v1.$K8S_MINOR"
    sed -i \
      -e '/^[[:space:]]*DRAConsumableCapacity:[[:space:]]*true[[:space:]]*$/d' \
      -e 's/,DRAConsumableCapacity=true//g' \
      -e 's|admissionregistration.k8s.io/v1beta1|admissionregistration.k8s.io/v1alpha1=true,resource.k8s.io/v1beta1=true|g' \
      "$kind_config"
  fi
  patch_candidate_e2e_local_image_tags || true
  patch_candidate_e2e_cluster_identity || true
  git -C "$CHECKOUT" diff -- hack/lib/install.sh hack/run-e2e-kind.sh hack/e2e-kind-config.yaml test/e2e > "$OUTPUT_DIR/candidate-environment.patch"
  [[ -s "$OUTPUT_DIR/candidate-environment.patch" ]] || die "Candidate environment patch is empty"
}

if [[ ${#E2E_RUNS[@]} -gt 0 ]]; then
  if stage_done candidate-e2e-patch; then
    [[ -s "$OUTPUT_DIR/candidate-environment.patch" ]] || die "saved Candidate E2E patch evidence is missing"
    log "reusing the patched Candidate E2E environment"
  else
    patch_e2e_environment
    mark_stage candidate-e2e-patch
  fi
  repaired_e2e_patch=false
  if patch_candidate_e2e_cluster_identity; then repaired_e2e_patch=true; fi
  if patch_candidate_e2e_local_image_tags; then repaired_e2e_patch=true; fi
  if patch_candidate_kwok_non_blocking; then repaired_e2e_patch=true; fi
  if [[ "$repaired_e2e_patch" == true ]]; then
    git -C "$CHECKOUT" diff -- hack/lib/install.sh hack/run-e2e-kind.sh hack/e2e-kind-config.yaml test/e2e > "$OUTPUT_DIR/candidate-environment.patch"
    [[ -s "$OUTPUT_DIR/candidate-environment.patch" ]] || die "repaired Candidate E2E patch evidence is empty"
    log "repaired the saved Candidate E2E offline environment"
  fi
fi

RUN_RESULTS_FILE="$OUTPUT_DIR/run-results.tsv"
RUN_RESULT_COUNT=0
RUN_FAILURE_COUNT=0
printf 'category\tname\tstatus\texit_code\tlog\n' > "$RUN_RESULTS_FILE"

record_run_result() {
  local category="$1" name="$2" status="$3" exit_code="$4" log_path="$5" label
  RUN_RESULT_COUNT=$((RUN_RESULT_COUNT + 1))
  if [[ "$status" == failed ]]; then RUN_FAILURE_COUNT=$((RUN_FAILURE_COUNT + 1)); fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$category" "$name" "$status" "$exit_code" "$log_path" >> "$RUN_RESULTS_FILE"
  case "$status" in
    passed) label="PASS" ;;
    previously-passed) label="PASS (completed earlier)" ;;
    failed) label="FAIL" ;;
    *) label="$status" ;;
  esac
  log "RESULT $label: $category/$name exit=$exit_code log=$log_path"
}

print_run_result_summary() {
  local category name status exit_code log_path label
  log "batch result summary: total=$RUN_RESULT_COUNT failed=$RUN_FAILURE_COUNT"
  while IFS=$'\t' read -r category name status exit_code log_path; do
    [[ "$category" != category ]] || continue
    case "$status" in
      passed) label="PASS" ;;
      previously-passed) label="PASS (completed earlier)" ;;
      failed) label="FAIL" ;;
      *) label="$status" ;;
    esac
    log "  $label $category/$name exit=$exit_code log=$log_path"
  done < "$RUN_RESULTS_FILE"
}

run_e2e_one() {
  local type="$1" number="$2" name runtime runtime_archive artifacts cleanup_value=1 batch_status
  local stage="e2e-${number}-${type,,}" purpose kubeconfig reuse_cluster=false
  local -a runtime_images=()
  if stage_done "$stage"; then
    log "skipping completed Candidate E2E $type"
    record_run_result e2e "$number-$type" previously-passed 0 "$OUTPUT_DIR/e2e-$number-$type/run.log"
    return
  fi
  name="$(cluster_name "e2e-${type,,}" "$number")"; runtime="$WORK_DIR/runtime-e2e-$number.txt"
  purpose="e2e-$number-${type,,}"; kubeconfig="$WORK_DIR/kubeconfig-e2e-$number"
  runtime_archive="$WORK_DIR/runtime-e2e-$number.tar"
  artifacts="$OUTPUT_DIR/e2e-$number-$type"; mkdir -p "$artifacts"
  build_e2e_contract_prerequisites "$type" "$artifacts"
  write_runtime_images "e2e-$type" "$runtime"
  mapfile -t runtime_images < "$runtime"
  [[ ${#runtime_images[@]} -gt 0 ]] || die "runtime image list is empty: $runtime"
  docker_save_archive "$runtime_archive" "${runtime_images[@]}"
  if cluster_exists "$name"; then
    validate_saved_cluster "$name" "$purpose" "$kubeconfig" "$E2E_HELM_RELEASE_NAME"
    kind load image-archive "$runtime_archive" --name "$name"
    reuse_cluster=true
  fi
  CURRENT_CLUSTER="$name"; CLUSTER_CREATED=true
  state_set ACTIVE_CLUSTER "$name"; state_set ACTIVE_PURPOSE "$purpose"
  [[ "$KEEP_CLUSTER" != true ]] || cleanup_value=0
  if [[ "$reuse_cluster" == true ]]; then
    log "restarting Candidate E2E $type in saved cluster $name"
  else
    log "running Candidate E2E $type in $name"
  fi
  set +e
  (
    set -e
    cd "$CHECKOUT"
    load_e2e_contract_environment "$type"
    if [[ "$reuse_cluster" == true ]]; then
      export KUBECONFIG="$kubeconfig" SKIP_CLUSTER_SETUP=1
    fi
    CLUSTER_NAME="$E2E_HELM_RELEASE_NAME" CLEANUP_CLUSTER="$cleanup_value" \
      KIND_OPT="--image $NODE_IMAGE --config $CHECKOUT/hack/e2e-kind-config.yaml" \
      IMAGE_PREFIX=volcanosh TAG="$CANDIDATE_COMMIT" OS=linux ARTIFACTS_PATH="$artifacts" \
      VPG_RUNTIME_IMAGE_ARCHIVE="$runtime_archive" VPG_KWOK_MANIFEST="$(resource_for_key kwok-manifest)" \
      VPG_KWOK_STAGE="$(resource_for_key kwok-stage)" VPG_RESUME_RUN_ID="$RUN_ID" \
      VPG_KIND_CLUSTER_NAME="$name" \
      VPG_CANDIDATE_COMMIT="$CANDIDATE_COMMIT" VPG_RESUME_PURPOSE="$purpose" bash hack/run-e2e-kind.sh
  ) 2>&1 | tee -a "$artifacts/run.log"
  batch_status=$?
  set -e
  if [[ "$batch_status" -eq 0 ]]; then
    mark_stage "$stage"
    record_run_result e2e "$number-$type" passed 0 "$artifacts/run.log"
  else
    record_run_result e2e "$number-$type" failed "$batch_status" "$artifacts/run.log"
  fi
  delete_cluster "e2e-$number"
  case "$batch_status" in 129|130|143) return "$batch_status" ;; esac
}

create_benchmark_cluster() {
  local name="$1" number="$2" purpose="$3" config runtime
  config="$WORK_DIR/kind-benchmark-$number.yaml"
  runtime="$WORK_DIR/runtime-benchmark-$number.txt"
  [[ -f "$CHECKOUT/benchmark/config/kind-config.yaml" ]] || die "Candidate Benchmark Kind config is missing"
  sed "s|__VOLCANO_ROOT__|$CHECKOUT|g" "$CHECKOUT/benchmark/config/kind-config.yaml" > "$config"
  CURRENT_CLUSTER="$name"; CLUSTER_CREATED=true
  KUBECONFIG="$OUTPUT_DIR/kubeconfig-benchmark-$number"; export KUBECONFIG
  if cluster_exists "$name"; then
    validate_saved_cluster "$name" "$purpose" "$KUBECONFIG" ""
    REUSED_CLUSTER=true
  else
    REUSED_CLUSTER=false
    state_set ACTIVE_CLUSTER "$name"; state_set ACTIVE_PURPOSE "$purpose"
    kind create cluster --name "$name" --image "$NODE_IMAGE" --config "$config" --wait 300s 2>&1 | tee "$OUTPUT_DIR/kind-create-benchmark-$number.log"
    kind get kubeconfig --name "$name" > "$KUBECONFIG"; chmod 0600 "$KUBECONFIG"
  fi
  observed="$(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
  [[ "$observed" == "$K8S_VERSION" ]] || die "Kubernetes version mismatch: expected $K8S_VERSION, got $observed"
  record_cluster_identity "$KUBECONFIG" "$purpose"
  write_runtime_images benchmark "$runtime"
  for image in "${CANDIDATE_IMAGES[@]}"; do printf '%s\n' "$image" >> "$runtime"; done
  sort -u -o "$runtime" "$runtime"; load_image_list "$name" "$runtime" 2>&1 | tee "$OUTPUT_DIR/kind-load-benchmark-$number.log"
  kubectl apply -f "$(resource_for_key kwok-manifest)"
  kubectl apply -f "$(resource_for_key kwok-stage)"
  kubectl wait --for=condition=Available deployment/kwok-controller -n kube-system --timeout=120s
}

install_candidate() {
  local number="$1" log_file="${2:-$OUTPUT_DIR/helm-install-benchmark-$1.log}"
  helm upgrade --install volcano "$CHECKOUT/installer/helm/chart/volcano" --namespace volcano-system \
    --create-namespace --set basic.image_pull_policy=IfNotPresent \
    --set "basic.image_tag_version=$CANDIDATE_COMMIT" \
    --set basic.scheduler_config_file=volcano-scheduler-configmap \
    --set "custom.agent_scheduler_enable=$BUILD_AGENT" \
    --set custom.scheduler_kube_api_qps=5000 --set custom.scheduler_kube_api_burst=10000 \
    --set custom.controller_kube_api_qps=5000 --set custom.controller_kube_api_burst=10000 \
    --wait --timeout 300s 2>&1 | tee "$log_file"
}

if [[ "$MANUAL_ACTION" == deploy-only ]]; then
  manual_name="$(manual_cluster_name "volcano-${CANDIDATE_COMMIT:0:8}")"
  manual_kubeconfig="$OUTPUT_DIR/kubeconfig"
  manual_images="$WORK_DIR/runtime-deploy-only.txt"
  create_manual_cluster "$manual_name" deploy-only "$manual_kubeconfig"
  if [[ "$MANUAL_CLUSTER_REUSED" == true ]] && stage_done manual-deploy-images; then
    log "reusing Candidate images already loaded into the manual cluster"
  else
    printf '%s\n' "${CANDIDATE_IMAGES[@]}" > "$manual_images"
    load_image_list "$manual_name" "$manual_images" 2>&1 | tee "$OUTPUT_DIR/kind-load-deploy-only.log"
    mark_stage manual-deploy-images
  fi
  if [[ "$MANUAL_CLUSTER_REUSED" == true ]] && stage_done manual-deploy-install; then
    helm status volcano -n volcano-system --kubeconfig "$manual_kubeconfig" -o json | \
      jq -e '.info.status=="deployed"' >/dev/null || die "saved manual Volcano release is not deployed"
    helm get values volcano -n volcano-system --kubeconfig "$manual_kubeconfig" --all -o json | \
      jq -e --arg commit "$CANDIDATE_COMMIT" '.basic.image_tag_version==$commit' >/dev/null || \
      die "saved manual Volcano release uses a different Candidate"
    log "validated and reusing the manual Volcano installation"
  else
    install_candidate manual "$OUTPUT_DIR/helm-install-deploy-only.log"
    mark_stage manual-deploy-install
  fi
  kubectl --kubeconfig "$manual_kubeconfig" -n volcano-system get pods -o wide \
    2>&1 | tee "$OUTPUT_DIR/volcano-system-pods.log"
  finish_manual_action "$manual_name" "$manual_kubeconfig"
fi

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
  local scenario="$1" configured="$2" number="$3" name config round round_dir purpose stage batch_status
  name="$(cluster_name "benchmark-${scenario,,}" "$number")"
  purpose="benchmark-$number-${scenario,,}"
  config="$(resolve_benchmark_config "$configured" "$number")"
  create_benchmark_cluster "$name" "$number" "$purpose"
  stage="benchmark-${number}-${scenario,,}-candidate"
  if [[ "$REUSED_CLUSTER" == true ]] && stage_done "$stage"; then
    validate_saved_cluster "$name" "$purpose" "$KUBECONFIG" volcano
    log "reusing the Candidate installation in saved Benchmark cluster"
  else
    install_candidate "$number"
    mark_stage "$stage"
  fi
  stage="benchmark-${number}-${scenario,,}-infrastructure"
  if [[ "$REUSED_CLUSTER" == true ]] && stage_done "$stage"; then
    log "reusing saved Candidate Benchmark KWOK infrastructure"
  else
    log "creating Candidate Benchmark KWOK nodes"
    if [[ "$configured" == *net-topo* ]]; then
      (cd "$CHECKOUT/benchmark"; ENABLE_TOPOLOGY=true USE_EXISTING_CLUSTER=true make create-nodes) \
        2>&1 | tee "$OUTPUT_DIR/benchmark-infrastructure-$number.log"
      (cd "$CHECKOUT/benchmark"; make create-hypernodes) 2>&1 | tee "$OUTPUT_DIR/benchmark-hypernodes-$number.log"
    else
      (cd "$CHECKOUT/benchmark"; USE_EXISTING_CLUSTER=true make create-nodes) \
        2>&1 | tee "$OUTPUT_DIR/benchmark-infrastructure-$number.log"
    fi
    mark_stage "$stage"
  fi
  stage="benchmark-${number}-${scenario,,}-monitoring"
  if has_image_key prometheus; then
    if [[ "$REUSED_CLUSTER" == true ]] && stage_done "$stage"; then
      log "reusing saved Candidate Benchmark monitoring"
    else
      prepare_monitoring "$name" "$number"
      mark_stage "$stage"
    fi
  fi
  if [[ "$REUSED_CLUSTER" == true ]]; then
    log "cleaning incomplete Benchmark workloads before continuing"
    (cd "$CHECKOUT/benchmark"; make clean-vcjobs) >/dev/null 2>&1 || true
  fi
  for ((round=1; round<=BENCHMARK_ROUNDS; round++)); do
    stage="benchmark-${number}-${scenario,,}-round-$round"
    printf -v round_dir '%s/benchmark-%02d-%s-round-%02d' "$OUTPUT_DIR" "$number" "$scenario" "$round"
    if stage_done "$stage"; then
      log "skipping completed Candidate Benchmark $scenario round $round/$BENCHMARK_ROUNDS"
      record_run_result benchmark "$number-$scenario-round-$round" previously-passed 0 "$round_dir/run.log"
      continue
    fi
    mkdir -p "$round_dir"
    log "running Candidate Benchmark $scenario round $round/$BENCHMARK_ROUNDS"
    set +e
    (
      set -e
      cd "$CHECKOUT/benchmark"
      set +e
      bash scripts/run-tests.sh "$scenario" "--config=$config"
      test_status=$?
      set -e
      [[ ! -d results ]] || cp -a results/. "$round_dir/"
      make clean-vcjobs || true
      exit "$test_status"
    ) 2>&1 | tee -a "$round_dir/run.log"
    batch_status=$?
    set -e
    if [[ "$batch_status" -eq 0 ]]; then
      mark_stage "$stage"
      record_run_result benchmark "$number-$scenario-round-$round" passed 0 "$round_dir/run.log"
    else
      record_run_result benchmark "$number-$scenario-round-$round" failed "$batch_status" "$round_dir/run.log"
    fi
    if [[ "$batch_status" == 129 || "$batch_status" == 130 || "$batch_status" == 143 ]]; then
      delete_cluster "benchmark-$number"
      return "$batch_status"
    fi
  done
  delete_cluster "benchmark-$number"
}

for ((index=0; index<${#E2E_RUNS[@]}; index++)); do run_e2e_one "${E2E_RUNS[$index]}" "$((index+1))"; done
for ((index=0; index<${#BENCHMARK_RUN_SCENARIOS[@]}; index++)); do
  run_benchmark_one "${BENCHMARK_RUN_SCENARIOS[$index]}" "${BENCHMARK_RUN_CONFIGS[$index]}" "$((index+1))"
done

if [[ "$RUN_FAILURE_COUNT" -eq 0 ]]; then OVERALL_STATUS=passed; else OVERALL_STATUS=failed; fi
cat > "$OUTPUT_DIR/summary.txt" <<EOF
status=$OVERALL_STATUS
script_version=$SCRIPT_VERSION
bundle_scope=$BUNDLE_SCOPE
profile=$PROFILE
mode=$MODE
kubernetes_version=$K8S_VERSION
kind_version=$KIND_VERSION
packaged_kind_versions=$(IFS=,; printf '%s' "${AVAILABLE_KIND_VERSIONS[*]}")
default_go_toolchain=$GO_TOOLCHAIN
selected_go_toolchain=$SELECTED_GO_TOOLCHAIN
packaged_go_toolchains=$(IFS=,; printf '%s' "${AVAILABLE_GO_VERSIONS[*]}")
candidate_repository=$VOLCANO_REPO
candidate_requested_ref=$VOLCANO_REF
candidate_commit=$CANDIDATE_COMMIT
e2e_selection=$E2E_SELECTION
benchmark_selection=$BENCHMARK_SELECTION
benchmark_rounds=$BENCHMARK_ROUNDS
resumed_work_directory=$RESUME_WORK
work_directory=$WORK_DIR
keep_work_directory=$KEEP_WORK_DIR
keep_cluster=$KEEP_CLUSTER
active_cluster=$(state_get ACTIVE_CLUSTER || true)
go_proxy=$GOPROXY_VALUE
go_nosumdb=$GONOSUMDB_VALUE
go_sumdb=$GOSUMDB_VALUE
go_module_delivery=inner-host-file-proxy
run_result_count=$RUN_RESULT_COUNT
run_failure_count=$RUN_FAILURE_COUNT
run_results_file=$RUN_RESULTS_FILE
finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
print_run_result_summary
if [[ "$RUN_FAILURE_COUNT" -gt 0 ]]; then
  log "completed all runnable batches with failures; results: $OUTPUT_DIR"
  exit 1
fi
log "completed successfully; results: $OUTPUT_DIR"
