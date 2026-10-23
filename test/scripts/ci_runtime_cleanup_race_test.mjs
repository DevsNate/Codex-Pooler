import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

function fixture(t) {
	const root = mkdtempSync(join(tmpdir(), "ci-cleanup-race-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const binary = join(root, "docker");
	const log = join(root, "calls");
	writeFileSync(
		binary,
		`#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$CALL_LOG"
case "$1 $2" in
  'container ls')
    if [[ "$*" == *--filter* ]]; then echo vanished-container
    else
      [[ \${ABSENCE_LIST_FAIL:-0} != 1 ]] || exit 55
      [[ \${STILL_PRESENT:-0} != 1 ]] || echo vanished-container
    fi ;;
  'container inspect')
    [[ "$RACE_STAGE" != inspect ]] || exit 44
    echo rehearsal-owned ;;
  'container rm') exit 44 ;;
  'network ls') echo owned-network ;;
  'network inspect') echo rehearsal-owned ;;
esac
`,
		{ mode: 0o755 },
	);
	return {
		log,
		run: (environment) =>
			spawnSync("bash", ["scripts/ci/run.sh", "cleanup"], {
				encoding: "utf8",
				env: {
					...process.env,
					GITHUB_ACTIONS: "false",
					CI_REHEARSAL: "true",
					CI_RUN_ID: "rehearsal-owned",
					CI_DOCKER_COMMAND: binary,
					CALL_LOG: log,
					...environment,
				},
			}),
	};
}

for (const stage of ["inspect", "remove"]) {
	test(`cleanup continues to networks when another cleaner removes a container during ${stage}`, (t) => {
		// Given an initially listed container that disappears at this Docker call.
		const subject = fixture(t);
		// When the actual cleanup CLI handles the concurrent removal.
		const result = subject.run({ RACE_STAGE: stage });
		// Then a successful unfiltered inventory proves absence and cleanup continues.
		assert.equal(result.status, 0, result.stderr);
		const calls = readFileSync(subject.log, "utf8");
		assert.match(calls, /container ls -aq --no-trunc\n/);
		assert.match(calls, /network rm owned-network/);
		assert.equal(result.stderr, "");
	});

	test(`cleanup fails when absence cannot be proven after a ${stage} error`, (t) => {
		// Given a failed operation followed by an unavailable Docker inventory.
		const subject = fixture(t);
		// When cleanup attempts to distinguish a race from a daemon failure.
		const result = subject.run({ RACE_STAGE: stage, ABSENCE_LIST_FAIL: "1" });
		// Then the API failure cannot be reclassified as successful cleanup.
		assert.notEqual(result.status, 0);
		assert.match(result.stderr, /cannot (inspect|remove) owned container/);
	});
}

test("cleanup preserves a container when inspection fails but inventory still contains it", (t) => {
	// Given an inspect error unrelated to disappearance.
	const subject = fixture(t);
	// When the actual cleanup command reads a successful inventory containing it.
	const result = subject.run({ RACE_STAGE: "inspect", STILL_PRESENT: "1" });
	// Then it fails without issuing an unauthenticated deletion.
	assert.notEqual(result.status, 0);
	assert.doesNotMatch(readFileSync(subject.log, "utf8"), /container rm/);
});
