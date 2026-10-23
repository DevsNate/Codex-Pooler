#!/usr/bin/env bash
set -euo pipefail

[[ $PWD == /workspace && ${CI:-} == true ]] || { echo 'CI workspace required' >&2; exit 2; }
phase() {
  local name=$1 started=$SECONDS rc=0
  shift
  printf 'phase=%s started\n' "$name"
  "$@" || rc=$?
  printf 'phase=%s seconds=%s exit=%s\n' "$name" "$((SECONDS - started))" "$rc"
  return "$rc"
}

# Each lane has its own cache volume, including Dialyxir's core PLTs in MIX_HOME.
mkdir -p "$MIX_HOME" "$HEX_HOME"
cp -a --update=none /root/.mix/. "$MIX_HOME/"
if [[ ${1:-} == quality ]]; then phase listener-cleanup mix quality.test_cleanup; fi
phase dependencies mix deps.get
case "${1:-}" in
  quality)
    phase compile mix compile --warnings-as-errors
    phase xref mix quality.xref
    phase format mix format --check-formatted
    phase security mix quality.security
    phase credo mix quality.credo
    # Preserve eight async modules per partition independently of BEAM scheduler count.
    phase product env TEST_FAST_COMMAND='mix test.product --warnings-as-errors --max-cases 8' make test-fast N=4
    phase tooling env TEST_FAST_COMMAND='mix test.tooling --warnings-as-errors --max-cases 8' make test-fast N=4
    ;;
  dialyzer)
    phase dialyzer mix quality.dialyzer
    ;;
  *) echo 'usage: phases.sh quality|dialyzer' >&2; exit 2 ;;
esac
