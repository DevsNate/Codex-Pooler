#!/usr/bin/env bash
# Sourced by run.sh after its run identity is validated.
docker_command=${docker_command:-docker}
run_id=${run_id:?run identity required}
cache_key=${cache_key:-}
docker_cli() { "$docker_command" "$@"; }
image_runtime_identity() {
  # Docker's top-level Id may identify a provenance-bearing index. Hash only the executable image.
  docker_cli image inspect "$1" | python3 -c '
import hashlib, json, sys
image = json.load(sys.stdin)[0]
runtime = {"os": image["Os"], "architecture": image["Architecture"], "variant": image.get("Variant", ""), "config": image["Config"], "rootfs": image["RootFS"]}
canonical = json.dumps(runtime, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(canonical).hexdigest())
'
}
resource_ids() {
  local kind=$1
  shift
  case "$kind" in
    container) docker_cli container ls -aq --no-trunc "$@" ;;
    network) docker_cli network ls -q --no-trunc "$@" ;;
    volume) docker_cli volume ls -q "$@" ;;
    *) return 2 ;;
  esac
}
resource_absent() {
  local kind=$1 id=$2 ids current
  # An inspect/remove error alone is not absence: an unfiltered successful list must prove it.
  ids=$(resource_ids "$kind") || return 1
  while IFS= read -r current; do
    [[ $current != "$id" ]] || return 1
  done <<< "$ids"
}
cleanup() {
  local kind id ids field actual message rc=0
  for kind in container network volume; do
    ids=$(resource_ids "$kind" --filter "label=io.codex-pooler.ci.run=$run_id") || return 1
    while IFS= read -r id; do
      [[ -n $id ]] || continue
      field='.Labels'
      [[ $kind != container ]] || field='.Config.Labels'
      if ! actual=$(docker_cli "$kind" inspect --format "{{ index $field \"io.codex-pooler.ci.run\" }}" "$id" 2>&1); then
        if resource_absent "$kind" "$id"; then continue; fi
        printf 'cannot inspect owned %s %s: %s\n' "$kind" "$id" "$actual" >&2
        return 1
      fi
      [[ $actual == "$run_id" ]] || { echo "refusing foreign $kind $id" >&2; return 1; }
      if [[ $kind == container ]]; then
        if message=$(docker_cli container rm -f "$id" 2>&1); then continue; fi
      else
        if message=$(docker_cli "$kind" rm "$id" 2>&1); then continue; fi
      fi
      if resource_absent "$kind" "$id"; then continue; fi
      printf 'cannot remove owned %s %s: %s\n' "$kind" "$id" "$message" >&2
      rc=1
    done <<< "$ids"
  done
  return "$rc"
}
cache_volume() {
  local name=$1 actual
  if docker_cli volume inspect "$name" >/dev/null 2>&1; then
    actual=$(docker_cli volume inspect --format '{{ index .Labels "io.codex-pooler.ci.cache" }}' "$name")
    [[ $actual == "$cache_key" ]] || { echo "foreign cache volume: $name" >&2; return 1; }
    printf 'cache_volume=%s state=hit\n' "$name"
  else
    docker_cli volume create --label "io.codex-pooler.ci.cache=$cache_key" "$name" >/dev/null
    printf 'cache_volume=%s state=created\n' "$name"
  fi
}
phase() {
  local name=$1 started=$SECONDS rc=0
  shift
  printf 'phase=%s started\n' "$name"
  "$@" || rc=$?
  printf 'phase=%s seconds=%s exit=%s\n' "$name" "$((SECONDS - started))" "$rc"
  return "$rc"
}
