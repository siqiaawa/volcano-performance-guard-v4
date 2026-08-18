#!/usr/bin/env bash
# External entrypoint: resolve one dependency profile, download exact tools,
# images and small network resources, then create a transport bundle.
set -Eeuo pipefail

SCRIPT_VERSION="v4.2.1"
DEFAULT_VOLCANO_REPO="https://github.com/volcano-sh/volcano.git"
DEFAULT_GOPROXY="https://proxy.golang.org,direct"
DEFAULT_GOSUMDB="sum.golang.org"

log() { printf '[vpg4-package] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
valid_semver() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_text() { [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *'|'* ]]; }

usage() {
  cat <<'EOF'
Usage:
  bash volcano-v4-package.sh --k8s-version vX.Y.Z --volcano-ref REF \
    --profile PROFILE --output DIR [options]

Required:
  --k8s-version VERSION       Exact Kubernetes version
  --volcano-ref REF           Volcano branch, tag or 40-character commit
  --profile PROFILE           Dependency profile from config/profiles.tsv
  --output DIR                Output directory

Overrides:
  --volcano-repo URL          Default: official Volcano repository
  --config-dir DIR            Default: config beside this script
  --kind-version VERSION      Required with --node-image for an unlisted K8s
  --node-image IMAGE          Exact kindest/node reference, preferably digest-pinned
  --helm-version VERSION      Override configured Helm version
  --go-version VERSION        Override Candidate Go toolchain, e.g. go1.25.0
  --goproxy VALUE             Go module source used for Candidate metadata fallback
  --gosumdb VALUE             Go checksum database
  --set-image KEY=IMAGE       Replace a selected configured image
  --add-image IMAGE           Add an exact Candidate-specific image

Inspection/output:
  --list-profiles             Print maintained profiles and exit
  --list-images               Resolve and print configured images without pulling
  --split-size SIZE           Optional split(1) size, e.g. 1900M
  --publish OWNER/REPOSITORY  Upload generated assets with gh
  --release-tag TAG           Required with --publish
  --keep-work-dir             Keep temporary staging
  -h, --help

The maintained project inputs are this script, volcano-v4-deploy.sh and the
two TSV files under config/. The bundle never contains Volcano source,
Candidate E2E/Benchmark source, Go module cache or final Volcano images.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_DIR="$SCRIPT_DIR/config"
VOLCANO_REPO="$DEFAULT_VOLCANO_REPO"
VOLCANO_REF=""; K8S_VERSION=""; PROFILE=""; OUTPUT_DIR=""
KIND_OVERRIDE=""; NODE_OVERRIDE=""; HELM_OVERRIDE=""; GO_OVERRIDE=""
GOPROXY_VALUE="${GOPROXY:-$DEFAULT_GOPROXY}"
GOSUMDB_VALUE="${GOSUMDB:-$DEFAULT_GOSUMDB}"
LIST_PROFILES=false; LIST_IMAGES=false; KEEP_WORK_DIR=false
SPLIT_SIZE=""; PUBLISH_REPO=""; RELEASE_TAG=""
OVERRIDES=(); ADDITIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s-version) K8S_VERSION="${2:-}"; shift 2 ;;
    --volcano-ref) VOLCANO_REF="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --volcano-repo) VOLCANO_REPO="${2:-}"; shift 2 ;;
    --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
    --kind-version) KIND_OVERRIDE="${2:-}"; shift 2 ;;
    --node-image) NODE_OVERRIDE="${2:-}"; shift 2 ;;
    --helm-version) HELM_OVERRIDE="${2:-}"; shift 2 ;;
    --go-version) GO_OVERRIDE="${2:-}"; shift 2 ;;
    --goproxy) GOPROXY_VALUE="${2:-}"; shift 2 ;;
    --gosumdb) GOSUMDB_VALUE="${2:-}"; shift 2 ;;
    --set-image) OVERRIDES+=("${2:-}"); shift 2 ;;
    --add-image) ADDITIONS+=("${2:-}"); shift 2 ;;
    --list-profiles) LIST_PROFILES=true; shift ;;
    --list-images) LIST_IMAGES=true; shift ;;
    --split-size) SPLIT_SIZE="${2:-}"; shift 2 ;;
    --publish) PUBLISH_REPO="${2:-}"; shift 2 ;;
    --release-tag) RELEASE_TAG="${2:-}"; shift 2 ;;
    --keep-work-dir) KEEP_WORK_DIR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

VERSIONS_CONFIG="$CONFIG_DIR/versions.tsv"
PROFILES_CONFIG="$CONFIG_DIR/profiles.tsv"
[[ -f "$VERSIONS_CONFIG" ]] || die "missing config: $VERSIONS_CONFIG"
[[ -f "$PROFILES_CONFIG" ]] || die "missing config: $PROFILES_CONFIG"

if [[ "$LIST_PROFILES" == true ]]; then
  awk -F'|' '$1=="PROFILE" {printf "%-30s mode=%-9s default=%s\n",$2,$3,$4}' "$PROFILES_CONFIG"
  exit 0
fi

[[ -n "$K8S_VERSION" ]] || die "--k8s-version is required"
[[ -n "$VOLCANO_REF" ]] || die "--volcano-ref is required"
[[ -n "$PROFILE" ]] || die "--profile is required"
[[ -n "$OUTPUT_DIR" || "$LIST_IMAGES" == true ]] || die "--output is required"
valid_semver "$K8S_VERSION" || die "--k8s-version must be exact vMAJOR.MINOR.PATCH"
valid_text "$VOLCANO_REPO" || die "invalid --volcano-repo"
valid_text "$VOLCANO_REF" || die "invalid --volcano-ref"
valid_text "$PROFILE" || die "invalid --profile"
valid_text "$GOPROXY_VALUE" || die "invalid --goproxy"
valid_text "$GOSUMDB_VALUE" || die "invalid --gosumdb"
[[ -z "$PUBLISH_REPO" || -n "$RELEASE_TAG" ]] || die "--release-tag is required with --publish"

HELM_VERSION=""; JQ_VERSION=""; JQ_SHA256=""; KWOK_VERSION=""
KIND_VERSION=""; NODE_IMAGE=""
while IFS='|' read -r type a b c extra; do
  [[ -n "$type" && "$type" != \#* ]] || continue
  case "$type" in
    DEFAULT)
      case "$a" in
        helm) HELM_VERSION="$b" ;;
        jq) JQ_VERSION="$b"; JQ_SHA256="$c" ;;
        kwok) KWOK_VERSION="$b" ;;
      esac
      ;;
    K8S)
      if [[ "$a" == "$K8S_VERSION" ]]; then KIND_VERSION="$b"; NODE_IMAGE="$c"; fi
      ;;
    *) die "unknown record in versions.tsv: $type" ;;
  esac
done < "$VERSIONS_CONFIG"
[[ -z "$HELM_OVERRIDE" ]] || HELM_VERSION="$HELM_OVERRIDE"
[[ -z "$KIND_OVERRIDE" ]] || KIND_VERSION="$KIND_OVERRIDE"
[[ -z "$NODE_OVERRIDE" ]] || NODE_IMAGE="$NODE_OVERRIDE"
if [[ -z "$KIND_VERSION" || -z "$NODE_IMAGE" ]]; then
  die "Kubernetes $K8S_VERSION is not fully configured; pass --kind-version and --node-image together"
fi
valid_semver "$KIND_VERSION" || die "invalid Kind version: $KIND_VERSION"
valid_semver "$HELM_VERSION" || die "invalid Helm version: $HELM_VERSION"
[[ "$JQ_VERSION" =~ ^jq-[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid jq version in config"
[[ "$JQ_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid jq checksum in config"
valid_semver "$KWOK_VERSION" || die "invalid KWOK version in config"

PROFILE_MODE=""; DEFAULT_RUN=""; PROFILE_GROUPS=""
E2E_FULL_TYPES=(); BENCHMARK_FULL_SCENARIOS=(); BENCHMARK_FULL_CONFIGS=()
while IFS='|' read -r type a b c d extra; do
  [[ -n "$type" && "$type" != \#* ]] || continue
  case "$type" in
    PROFILE)
      if [[ "$a" == "$PROFILE" ]]; then PROFILE_MODE="$b"; DEFAULT_RUN="$c"; PROFILE_GROUPS="$d"; fi
      ;;
    E2E_FULL) E2E_FULL_TYPES+=("$a") ;;
    BENCHMARK_FULL) BENCHMARK_FULL_SCENARIOS+=("$a"); BENCHMARK_FULL_CONFIGS+=("$b") ;;
    IMAGE|RESOURCE) ;;
    *) die "unknown record in profiles.tsv: $type" ;;
  esac
done < "$PROFILES_CONFIG"
[[ "$PROFILE_MODE" == "e2e" || "$PROFILE_MODE" == "benchmark" || "$PROFILE_MODE" == "both" ]] || \
  die "unknown profile: $PROFILE (use --list-profiles)"

group_selected() {
  local wanted="$1" item
  IFS=',' read -ra selected_groups <<< "$PROFILE_GROUPS"
  for item in "${selected_groups[@]}"; do [[ "$item" == "$wanted" ]] && return 0; done
  return 1
}

IMAGE_KEYS=(); IMAGE_PULL_REFS=(); IMAGE_SAVE_REFS=()
RESOURCE_KEYS=(); RESOURCE_URLS=(); RESOURCE_PATHS=()
set_image() {
  local key="$1" pull_ref="$2" save_ref="$3" index
  [[ "$key" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid image key: $key"
  valid_text "$pull_ref" || die "invalid image reference for $key: $(printf '%q' "$pull_ref")"
  valid_text "$save_ref" || die "invalid local image reference for $key: $(printf '%q' "$save_ref")"
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    if [[ "${IMAGE_KEYS[$index]}" == "$key" ]]; then
      IMAGE_PULL_REFS[index]="$pull_ref"; IMAGE_SAVE_REFS[index]="$save_ref"; return
    fi
  done
  IMAGE_KEYS+=("$key"); IMAGE_PULL_REFS+=("$pull_ref"); IMAGE_SAVE_REFS+=("$save_ref")
}
set_resource() {
  local key="$1" url="$2" path="$3" index
  for ((index=0; index<${#RESOURCE_KEYS[@]}; index++)); do
    [[ "${RESOURCE_KEYS[$index]}" != "$key" ]] || return 0
  done
  RESOURCE_KEYS+=("$key"); RESOURCE_URLS+=("$url"); RESOURCE_PATHS+=("$path")
}

set_image kind-node "$NODE_IMAGE" "${NODE_IMAGE%@*}"
while IFS='|' read -r type group key value output extra; do
  [[ -n "$type" && "$type" != \#* ]] || continue
  [[ "$type" == IMAGE || "$type" == RESOURCE ]] || continue
  group_selected "$group" || continue
  case "$type" in
    IMAGE) set_image "$key" "$value" "$output" ;;
    RESOURCE)
      value="${value//'${KWOK_VERSION}'/$KWOK_VERSION}"
      set_resource "$key" "$value" "$output"
      ;;
  esac
done < "$PROFILES_CONFIG"

for override in "${OVERRIDES[@]}"; do
  [[ "$override" == *=* ]] || die "--set-image expects KEY=IMAGE: $override"
  key="${override%%=*}"; ref="${override#*=}"; found=false
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    if [[ "${IMAGE_KEYS[$index]}" == "$key" ]]; then
      # Pulling may use an accessible mirror, but the local tag must remain the
      # exact reference used by Candidate YAML/Dockerfiles.
      IMAGE_PULL_REFS[index]="$ref"; found=true
    fi
  done
  [[ "$found" == true ]] || die "--set-image key is not selected: $key"
done
for ((index=0; index<${#ADDITIONS[@]}; index++)); do
  set_image "extra-$((index+1))" "${ADDITIONS[$index]}" "${ADDITIONS[$index]%@*}"
done

for command in git awk mktemp; do need "$command"; done

resolve_commit() {
  local repo="$1" ref="$2" line commit="" verify_dir
  if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    verify_dir="$(mktemp -d /tmp/volcano-v4-resolve.XXXXXX)"
    git -C "$verify_dir" init >/dev/null
    if git -C "$verify_dir" fetch --quiet --depth 1 "$repo" "$ref"; then
      commit="$(git -C "$verify_dir" rev-parse FETCH_HEAD)"
    fi
    rm -rf -- "$verify_dir"
  else
    while read -r line; do
      [[ -n "$line" ]] || continue
      if [[ "${line#*$'\t'}" == "refs/tags/$ref^{}" ]]; then commit="${line%%$'\t'*}"; break; fi
      [[ -n "$commit" ]] || commit="${line%%$'\t'*}"
    done < <(git ls-remote "$repo" "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}")
  fi
  [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  printf '%s\n' "${commit,,}"
}

VOLCANO_COMMIT="$(resolve_commit "$VOLCANO_REPO" "$VOLCANO_REF")" || die "cannot resolve Volcano ref: $VOLCANO_REF"
if [[ "$LIST_IMAGES" == true ]]; then
  printf 'profile=%s\nmode=%s\nkubernetes=%s\nkind=%s\nnode=%s\nvolcano=%s\n' \
    "$PROFILE" "$PROFILE_MODE" "$K8S_VERSION" "$KIND_VERSION" "$NODE_IMAGE" "$VOLCANO_COMMIT"
  for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
    printf '%s=%s -> %s\n' "${IMAGE_KEYS[$index]}" "${IMAGE_PULL_REFS[$index]}" "${IMAGE_SAVE_REFS[$index]}"
  done
  printf 'Candidate Dockerfile bases are checked and appended during a real package run.\n'
  exit 0
fi

for command in curl docker tar gzip sha256sum sed grep sort; do need "$command"; done
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "packaging requires Linux x86_64"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
safe_k8s="${K8S_VERSION#v}"; safe_profile="${PROFILE//[^a-zA-Z0-9._-]/-}"
BUNDLE_NAME="volcano-v4-${safe_k8s}-${VOLCANO_COMMIT:0:12}-${safe_profile}"
BUNDLE_PATH="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
[[ ! -e "$BUNDLE_PATH" ]] || die "output already exists: $BUNDLE_PATH"
WORK_DIR="$(mktemp -d /tmp/volcano-v4-package.XXXXXX)"
STAGE="$WORK_DIR/$BUNDLE_NAME"; TOOLS_STAGE="$WORK_DIR/tools"; TOOLS_BIN="$TOOLS_STAGE/bin"
RESOURCES_STAGE="$WORK_DIR/resources"; META_CHECKOUT="$WORK_DIR/meta-source"
mkdir -p "$STAGE" "$TOOLS_BIN" "$RESOURCES_STAGE"
cleanup() { status=$?; if [[ "$KEEP_WORK_DIR" == true ]]; then log "kept work directory: $WORK_DIR"; else rm -rf -- "$WORK_DIR"; fi; exit "$status"; }
trap cleanup EXIT
cp "$SCRIPT_DIR/volcano-v4-deploy.sh" "$STAGE/volcano-v4-deploy.sh"

github_raw_base=""
if [[ "$VOLCANO_REPO" =~ ^https://github\.com/([^/]+)/([^/]+)(\.git)?$ ]]; then
  github_owner="${BASH_REMATCH[1]}"; github_repo="${BASH_REMATCH[2]%.git}"
  github_raw_base="https://raw.githubusercontent.com/$github_owner/$github_repo/$VOLCANO_COMMIT"
fi
meta_checkout_ready=false
candidate_file() {
  local path="$1" destination="$2"
  if [[ -n "$github_raw_base" ]] && curl --fail --location --silent --show-error \
      --retry 2 -o "$destination" "$github_raw_base/$path"; then return 0; fi
  if [[ "$meta_checkout_ready" != true ]]; then
    git init "$META_CHECKOUT" >/dev/null
    git -C "$META_CHECKOUT" remote add origin "$VOLCANO_REPO"
    git -C "$META_CHECKOUT" fetch --depth 1 origin "$VOLCANO_COMMIT" >/dev/null
    meta_checkout_ready=true
  fi
  git -C "$META_CHECKOUT" show "FETCH_HEAD:$path" > "$destination"
}

CANDIDATE_GO_MOD="$WORK_DIR/candidate.go.mod"
candidate_file go.mod "$CANDIDATE_GO_MOD" || die "cannot read Candidate go.mod"
GO_DIRECTIVE="$(awk '$1=="go" && NF==2 {print $2; exit}' "$CANDIDATE_GO_MOD")"
GO_TOOLCHAIN="$(awk '$1=="toolchain" && NF==2 {print $2; exit}' "$CANDIDATE_GO_MOD")"
[[ -n "$GO_TOOLCHAIN" ]] || GO_TOOLCHAIN="go$GO_DIRECTIVE"
[[ -z "$GO_OVERRIDE" ]] || GO_TOOLCHAIN="$GO_OVERRIDE"
[[ "$GO_TOOLCHAIN" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Candidate Go version is not exact: $GO_TOOLCHAIN"

dockerfiles=(scheduler controller-manager webhook-manager)
if [[ "$DEFAULT_RUN" == FULL || "$DEFAULT_RUN" == pod || "$DEFAULT_RUN" == AGENTSCHEDULER* ]]; then
  dockerfiles+=(agent-scheduler)
fi
if group_selected benchmark-monitoring; then dockerfiles+=(benchmark-audit-exporter); fi
base_number=0
for name in "${dockerfiles[@]}"; do
  if [[ "$name" == benchmark-audit-exporter ]]; then path="benchmark/manifests/audit-exporter/Dockerfile"
  else path="installer/dockerfile/$name/Dockerfile"; fi
  file="$WORK_DIR/${name}.Dockerfile"
  candidate_file "$path" "$file" || die "Candidate Dockerfile is missing: $path"
  while IFS= read -r base; do
    [[ "$base" != *'${'* ]] || die "unresolved Candidate base image in $path: $base"
    duplicate=false
    for ref in "${IMAGE_SAVE_REFS[@]}"; do [[ "$ref" == "${base%@*}" ]] && duplicate=true; done
    if [[ "$duplicate" != true ]]; then
      base_number=$((base_number+1)); set_image "candidate-base-$base_number" "$base" "${base%@*}"
    fi
  # Some upstream Dockerfiles use CRLF (for example agent-scheduler v1.15.0).
  done < <(awk 'toupper($1)=="FROM" {for(i=2;i<=NF;i++) if($i !~ /^--/) {gsub(/\r/,"",$i); print $i; break}}' "$file" | sort -u)
done

download_verified() {
  local url="$1" checksum_url="$2" output="$3" expected actual
  curl --fail --location --retry 3 --connect-timeout 30 -o "$output.part" "$url"
  expected="$(curl --fail --location --retry 3 --connect-timeout 30 "$checksum_url" | awk 'match($0,/[0-9a-fA-F]{64}/){print tolower(substr($0,RSTART,RLENGTH)); exit}')"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "cannot read checksum: $checksum_url"
  actual="$(sha256sum "$output.part" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "download checksum mismatch: $url"
  mv "$output.part" "$output"
}

log "downloading exact tools"
download_verified \
  "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
  "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64.sha256sum" \
  "$TOOLS_BIN/kind"
download_verified \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256" \
  "$TOOLS_BIN/kubectl"
helm_archive="$WORK_DIR/helm.tar.gz"
download_verified \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
  "$helm_archive"
tar -xzf "$helm_archive" -C "$WORK_DIR"
mv "$WORK_DIR/linux-amd64/helm" "$TOOLS_BIN/helm"
curl --fail --location --retry 3 --connect-timeout 30 -o "$TOOLS_BIN/jq" \
  "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64"
[[ "$(sha256sum "$TOOLS_BIN/jq" | awk '{print $1}')" == "$JQ_SHA256" ]] || die "jq checksum mismatch"
chmod 0755 "$TOOLS_BIN/kind" "$TOOLS_BIN/kubectl" "$TOOLS_BIN/helm" "$TOOLS_BIN/jq"

go_filename="${GO_TOOLCHAIN}.linux-amd64.tar.gz"; go_archive="$WORK_DIR/$go_filename"
go_index="$WORK_DIR/go-releases.json"
curl --fail --location --retry 3 --connect-timeout 30 -o "$go_index" 'https://go.dev/dl/?mode=json&include=all'
go_sha="$("$TOOLS_BIN/jq" -r --arg v "$GO_TOOLCHAIN" --arg f "$go_filename" \
  '.[]|select(.version==$v)|.files[]|select(.filename==$f and .os=="linux" and .arch=="amd64")|.sha256' "$go_index" | head -n1)"
[[ "$go_sha" =~ ^[0-9a-f]{64}$ ]] || die "Go archive is absent from official index: $GO_TOOLCHAIN"
curl --fail --location --retry 3 --connect-timeout 30 -o "$go_archive" "https://go.dev/dl/$go_filename"
[[ "$(sha256sum "$go_archive" | awk '{print $1}')" == "$go_sha" ]] || die "Go checksum mismatch"
tar -xzf "$go_archive" -C "$TOOLS_STAGE"
tar -C "$TOOLS_STAGE" -czf "$STAGE/tools.tar.gz" .

log "downloading ${#RESOURCE_KEYS[@]} small resources"
RESOURCE_SHAS=()
for ((index=0; index<${#RESOURCE_KEYS[@]}; index++)); do
  path="${RESOURCE_PATHS[$index]}"; [[ "$path" != /* && "$path" != *'..'* ]] || die "unsafe resource path: $path"
  mkdir -p "$RESOURCES_STAGE/$(dirname "$path")"
  curl --fail --location --retry 3 --connect-timeout 30 -o "$RESOURCES_STAGE/$path" "${RESOURCE_URLS[$index]}"
  RESOURCE_SHAS+=("$(sha256sum "$RESOURCES_STAGE/$path" | awk '{print $1}')")
done
tar -C "$RESOURCES_STAGE" -czf "$STAGE/resources.tar.gz" .

META="$STAGE/bundle.meta"
{
  printf 'FORMAT=volcano-performance-guard-v4\nSCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
  printf 'CREATED_AT=%s\nPLATFORM=linux/amd64\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'PROFILE=%s\nMODE=%s\nDEFAULT_RUN=%s\n' "$PROFILE" "$PROFILE_MODE" "$DEFAULT_RUN"
  printf 'K8S_VERSION=%s\nKIND_VERSION=%s\nHELM_VERSION=%s\nJQ_VERSION=%s\nKWOK_VERSION=%s\nGO_TOOLCHAIN=%s\n' \
    "$K8S_VERSION" "$KIND_VERSION" "$HELM_VERSION" "$JQ_VERSION" "$KWOK_VERSION" "$GO_TOOLCHAIN"
  printf 'VOLCANO_REPO=%s\nVOLCANO_REF=%s\nVOLCANO_COMMIT=%s\n' "$VOLCANO_REPO" "$VOLCANO_REF" "$VOLCANO_COMMIT"
  printf 'TOOL=kind|%s|bin/kind|%s\n' "$KIND_VERSION" "$(sha256sum "$TOOLS_BIN/kind"|awk '{print $1}')"
  printf 'TOOL=kubectl|%s|bin/kubectl|%s\n' "$K8S_VERSION" "$(sha256sum "$TOOLS_BIN/kubectl"|awk '{print $1}')"
  printf 'TOOL=helm|%s|bin/helm|%s\n' "$HELM_VERSION" "$(sha256sum "$TOOLS_BIN/helm"|awk '{print $1}')"
  printf 'TOOL=jq|%s|bin/jq|%s\n' "$JQ_VERSION" "$(sha256sum "$TOOLS_BIN/jq"|awk '{print $1}')"
  printf 'TOOL=go|%s|go/bin/go|%s\n' "$GO_TOOLCHAIN" "$(sha256sum "$TOOLS_STAGE/go/bin/go"|awk '{print $1}')"
  for ((index=0; index<${#RESOURCE_KEYS[@]}; index++)); do
    printf 'RESOURCE=%s|%s|%s\n' "${RESOURCE_KEYS[$index]}" "${RESOURCE_PATHS[$index]}" "${RESOURCE_SHAS[$index]}"
  done
  if [[ "$PROFILE_MODE" != benchmark ]]; then
    if [[ "$DEFAULT_RUN" == FULL ]]; then for value in "${E2E_FULL_TYPES[@]}"; do printf 'E2E_CAP=%s\n' "$value"; done
    else printf 'E2E_CAP=%s\n' "$DEFAULT_RUN"; fi
  fi
  if [[ "$PROFILE_MODE" != e2e ]]; then
    if [[ "$DEFAULT_RUN" == FULL ]]; then
      for ((index=0; index<${#BENCHMARK_FULL_SCENARIOS[@]}; index++)); do
        printf 'BENCHMARK_CAP=%s|%s\n' "${BENCHMARK_FULL_SCENARIOS[$index]}" "${BENCHMARK_FULL_CONFIGS[$index]}"
      done
    elif [[ "$DEFAULT_RUN" == pod ]]; then printf 'BENCHMARK_CAP=pod|GENERATED_POD\n'
    else printf 'BENCHMARK_CAP=%s|benchmark/testcases/%s/cases/comprehensive.yaml\n' "$DEFAULT_RUN" "$DEFAULT_RUN"; fi
  fi
} > "$META"

SAVE_REFS=(); PULLED_REFS=()
append_unique() { local v="$1" x; for x in "${SAVE_REFS[@]}"; do [[ "$x" == "$v" ]] && return; done; SAVE_REFS+=("$v"); }
pull_once() { local v="$1" x; for x in "${PULLED_REFS[@]}"; do [[ "$x" == "$v" ]] && return; done; docker pull --platform linux/amd64 "$v"; PULLED_REFS+=("$v"); }
for ((index=0; index<${#IMAGE_KEYS[@]}; index++)); do
  key="${IMAGE_KEYS[$index]}"; pull_ref="${IMAGE_PULL_REFS[$index]}"; save_ref="${IMAGE_SAVE_REFS[$index]}"
  log "pulling [$key] $pull_ref"
  pull_once "$pull_ref"
  inspect="$(docker image inspect --format '{{.Os}}/{{.Architecture}}|{{.Id}}' "$pull_ref")"
  [[ "${inspect%%|*}" == linux/amd64 ]] || die "image platform mismatch: $pull_ref"
  image_id="${inspect#*|}"; [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid image ID: $pull_ref"
  [[ "$pull_ref" == "$save_ref" ]] || docker tag "$pull_ref" "$save_ref"
  append_unique "$save_ref"
  printf 'IMAGE=%s|%s|%s|%s|-\n' "$key" "$pull_ref" "$save_ref" "$image_id" >> "$META"
done

log "saving ${#SAVE_REFS[@]} unique local image tags"
docker image save "${SAVE_REFS[@]}" | gzip -1 -n > "$STAGE/images.tar.gz"
(
  cd "$STAGE"
  sha256sum bundle.meta images.tar.gz tools.tar.gz resources.tar.gz volcano-v4-deploy.sh > SHA256SUMS
)
tar -C "$WORK_DIR" -czf "$BUNDLE_PATH" "$BUNDLE_NAME"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$BUNDLE_PATH")" > "$(basename "$BUNDLE_PATH").sha256")
log "bundle created: $BUNDLE_PATH"
log "bundle SHA256: $(awk '{print $1}' "${BUNDLE_PATH}.sha256")"

UPLOAD_ASSETS=("$BUNDLE_PATH" "${BUNDLE_PATH}.sha256")
if [[ -n "$SPLIT_SIZE" ]]; then
  need split
  split -b "$SPLIT_SIZE" -d -a 3 "$BUNDLE_PATH" "${BUNDLE_PATH}.part-"
  (cd "$OUTPUT_DIR" && sha256sum "$(basename "$BUNDLE_PATH").part-"* > "$(basename "$BUNDLE_PATH").parts.sha256")
  UPLOAD_ASSETS=("${BUNDLE_PATH}.part-"* "${BUNDLE_PATH}.parts.sha256")
fi
if [[ -n "$PUBLISH_REPO" ]]; then
  need gh
  gh release view "$RELEASE_TAG" --repo "$PUBLISH_REPO" >/dev/null 2>&1 || \
    gh release create "$RELEASE_TAG" --repo "$PUBLISH_REPO" --title "$RELEASE_TAG" --notes "Volcano dependency bundle $SCRIPT_VERSION"
  gh release upload "$RELEASE_TAG" "${UPLOAD_ASSETS[@]}" --repo "$PUBLISH_REPO" --clobber
fi
