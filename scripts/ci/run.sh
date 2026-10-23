#!/usr/bin/env bash
set -euo pipefail
umask 022
fail() { printf 'pooler-ci: %s\n' "$*" >&2; exit 2; }
case "${1:-run}" in
  -h|--help) echo 'usage: bash scripts/ci/run.sh run|cleanup'; exit 0 ;;
  run|cleanup) mode=${1:-run} ;;
  *) fail 'usage: bash scripts/ci/run.sh run|cleanup' ;;
esac
[[ $# -le 1 ]] || fail 'unexpected arguments'
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
docker_command=${CI_DOCKER_COMMAND:-docker}
run_id=${CI_RUN_ID:-}
scope=rehearsal
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
  [[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] || fail 'invalid GitHub run identity'
  [[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail 'invalid source revision'
  [[ ${GITHUB_EVENT_NAME:-} == push && ${GITHUB_REF:-} == refs/heads/* ]] || fail 'only branch pushes may use this runner'
  run_id="github-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  scope=branch
  [[ $GITHUB_REF != refs/heads/main ]] || scope=main
else
  [[ ${CI_REHEARSAL:-} == true ]] || fail 'use rehearse.mjs outside GitHub Actions'
fi
[[ $run_id =~ ^[a-z][a-z0-9-]{5,70}$ ]] || fail 'invalid CI run identity'
# shellcheck source=scripts/ci/resources.sh
source "$repo/scripts/ci/resources.sh"
[[ $mode != cleanup ]] || { cleanup; exit; }
[[ $(docker_cli info --format '{{.OSType}}/{{.Architecture}}') =~ ^linux/(amd64|x86_64)$ ]] || fail 'native Linux amd64 Docker daemon required'
output=${CI_OUTPUT_DIR:-"$repo/tmp/ci-results/$run_id"}
mkdir -p "$output"
output=$(cd "$output" && pwd)
exec > >(tee "$output/run.log") 2>&1
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
  [[ $(git rev-parse HEAD) == "$GITHUB_SHA" ]] || fail 'checkout revision differs from event'
  [[ -z $(git status --porcelain --untracked-files=all) ]] || fail 'GitHub checkout must be clean'
  node scripts/ci/snapshot.mjs "$repo" "$output/snapshot"
  archive="$output/snapshot/source.tar"
  receipt="$output/snapshot/source.json"
else
  archive=${CI_SOURCE_ARCHIVE:?snapshot archive required}
  receipt=${CI_SOURCE_RECEIPT:?snapshot receipt required}
fi
cp "$receipt" "$output/source.json"
chmod 0644 "$output/source.json"
started=$SECONDS
finish() {
  local rc=$? cleanup_rc=0
  trap - EXIT INT TERM HUP
  cleanup || cleanup_rc=$?
  [[ $cleanup_rc -eq 0 ]] || { echo 'owned resource cleanup failed'; [[ $rc -ne 0 ]] || rc=1; }
  printf '{"run":"%s","exit":%s,"cleanupExit":%s,"seconds":%s}\n' "$run_id" "$rc" "$cleanup_rc" "$((SECONDS - started))" > "$output/receipt.json"
  exit "$rc"
}
[[ -z $(docker_cli container ls -aq --filter "label=io.codex-pooler.ci.run=$run_id") ]] || fail 'run already owns containers; clean it first'
[[ -z $(docker_cli network ls -q --filter "label=io.codex-pooler.ci.run=$run_id") ]] || fail 'run already owns a network; clean it first'
[[ -z $(docker_cli volume ls -q --filter "label=io.codex-pooler.ci.run=$run_id") ]] || fail 'run already owns workspaces; clean it first'
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
image_key=$(sha256sum scripts/ci/Dockerfile | cut -c1-20)
image="pooler-ci-tools:amd64-$image_key"
phase tools docker_cli build --builder default --platform linux/amd64 --provenance=false --tag "$image" - < scripts/ci/Dockerfile
runtime_identity=$(image_runtime_identity "$image")
cache_key=$(printf '%s\n' "$scope" "$runtime_identity" "$(sha256sum mix.lock)" | sha256sum | cut -c1-24)
printf 'tools_runtime_identity=%s cache_scope=%s cache_key=%s\n' "$runtime_identity" "$scope" "$cache_key"
prefix="pooler-ci-$run_id"
label="io.codex-pooler.ci.run=$run_id"
# An atomic named container lease excludes overlapping writers of the same full-gate caches.
docker_cli create --name "pooler-ci-cache-$cache_key" --label "$label" "$image" true >/dev/null
network="$prefix-network"
docker_cli network create --label "$label" "$network" >/dev/null
docker_cli run -d --name "$prefix-pg" --label "$label" --network "$network" --network-alias pg \
  --tmpfs /var/lib/postgresql:rw,size=4g --shm-size=256m \
  -e POSTGRES_DB=codex_pooler_test -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  postgres:18 -c max_connections=400 >/dev/null
ready=0
for _ in $(seq 1 120); do
  if docker_cli exec "$prefix-pg" pg_isready -h 127.0.0.1 -U postgres -d codex_pooler_test >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[[ $ready == 1 ]] || { docker_cli logs "$prefix-pg"; fail 'PostgreSQL did not become ready'; }
for lane in quality dialyzer; do
  workspace="$prefix-$lane-workspace"
  docker_cli volume create --label "$label" "$workspace" >/dev/null
  docker_cli run --rm -i --label "$label" --mount "type=volume,src=$workspace,dst=/workspace" "$image" tar -xf - -C /workspace < "$archive"
  mounts=(--mount "type=volume,src=$workspace,dst=/workspace")
  for part in build deps home; do
    volume="pooler-ci-$cache_key-$lane-$part"
    cache_volume "$volume"
    case "$part" in build) target=/workspace/_build ;; deps) target=/workspace/deps ;; home) target=/cache ;; esac
    mounts+=(--mount "type=volume,src=$volume,dst=$target")
  done
  extra=()
  [[ $lane != dialyzer ]] || extra=(-e 'ERL_FLAGS=+S 4:4')
  docker_cli create --name "$prefix-$lane" --label "$label" --network "$network" "${mounts[@]}" "${extra[@]}" \
    -e CI=true -e MIX_ENV=test -e MIX_HOME=/cache/mix -e HEX_HOME=/cache/hex \
    -e MIX_BUILD_PATH=/workspace/_build -e MIX_DEPS_PATH=/workspace/deps \
    -e POSTGRES_HOST=pg -e POSTGRES_PORT=5432 -e POSTGRES_DB=codex_pooler_test -e POSTGRES_TEST_DB=codex_pooler_test \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e TEST_FAST_PRINT_FILE_DURATIONS=1 \
    "$image" bash scripts/ci/phases.sh "$lane" >/dev/null
done
docker_cli start "$prefix-dialyzer" "$prefix-quality" >/dev/null
docker_cli logs --follow "$prefix-dialyzer" 2>&1 | tee "$output/dialyzer.log" &
dialyzer_log_pid=$!
docker_cli logs --follow "$prefix-quality" 2>&1 | tee "$output/quality.log" &
quality_log_pid=$!
quality_rc=$(docker_cli wait "$prefix-quality")
dialyzer_rc=$(docker_cli wait "$prefix-dialyzer")
wait "$quality_log_pid"
wait "$dialyzer_log_pid"
printf 'quality_exit=%s dialyzer_exit=%s\n' "$quality_rc" "$dialyzer_rc"
[[ $quality_rc == 0 && $dialyzer_rc == 0 ]]
