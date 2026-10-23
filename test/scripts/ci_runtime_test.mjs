import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const resources = resolve("scripts/ci/resources.sh");
function cleanupFixture(t, behavior) {
	const root = mkdtempSync(join(tmpdir(), "ci-cleanup-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const docker = join(root, "docker");
	const log = join(root, "calls");
	writeFileSync(
		docker,
		`#!/usr/bin/env bash\nset -eu\nprintf '%s\\n' "$*" >> "$CALL_LOG"\n${behavior}\n`,
		{ mode: 0o755 },
	);
	return { docker, log };
}

test("cleanup preserves a resource whose observed owner differs", (t) => {
	// Given a stale listing with foreign ownership at inspect time.
	const fixture = cleanupFixture(
		t,
		'case "$2" in ls) [[ $1 != container ]] || echo candidate ;; inspect) echo foreign-run ;; rm) exit 99 ;; esac',
	);
	// When cleanup executes against that daemon boundary.
	const result = spawnSync(
		"bash",
		["-c", 'set -eu; source "$RESOURCES"; cleanup'],
		{
			encoding: "utf8",
			env: {
				...process.env,
				RESOURCES: resources,
				docker_command: fixture.docker,
				run_id: "rehearsal-owned",
				CALL_LOG: fixture.log,
			},
		},
	);
	// Then cleanup fails without attempting deletion.
	assert.notEqual(result.status, 0);
	assert.doesNotMatch(readFileSync(fixture.log, "utf8"), / rm /);
});

test("cleanup propagates daemon deletion failures", (t) => {
	// Given an owned container that the daemon refuses to delete.
	const fixture = cleanupFixture(
		t,
		'case "$2" in ls) [[ $1 != container ]] || echo candidate ;; inspect) echo rehearsal-owned ;; rm) exit 7 ;; esac',
	);
	// When cleanup executes.
	const result = spawnSync(
		"bash",
		["-c", 'set -eu; source "$RESOURCES"; cleanup'],
		{
			encoding: "utf8",
			env: {
				...process.env,
				RESOURCES: resources,
				docker_command: fixture.docker,
				run_id: "rehearsal-owned",
				CALL_LOG: fixture.log,
			},
		},
	);
	// Then its caller receives failure.
	assert.notEqual(result.status, 0);
	assert.match(readFileSync(fixture.log, "utf8"), /container rm -f candidate/);
});

test("cleanup includes stopped containers before removing their volumes", (t) => {
	// Given an exited lane and a created cache lease, absent from running-only listings.
	const fixture = cleanupFixture(
		t,
		'case "$1 $2" in "container ls") [[ $3 != -aq ]] || printf "exited-lane\\ncreated-lease\\n" ;; "container inspect") echo rehearsal-owned ;; esac',
	);
	// When the exact owned resources are cleaned.
	const result = spawnSync(
		"bash",
		["-c", 'set -eu; source "$RESOURCES"; cleanup'],
		{
			encoding: "utf8",
			env: {
				...process.env,
				RESOURCES: resources,
				docker_command: fixture.docker,
				run_id: "rehearsal-owned",
				CALL_LOG: fixture.log,
			},
		},
	);
	// Then both non-running containers are removed.
	assert.equal(result.status, 0);
	const calls = readFileSync(fixture.log, "utf8");
	assert.match(calls, /container rm -f exited-lane/);
	assert.match(calls, /container rm -f created-lease/);
});

test("phase returns the actual failing command status", () => {
	// Given a command that fails deliberately, when run through phase logging.
	const result = spawnSync(
		"bash",
		[
			"-c",
			'run_id=rehearsal-test; source "$1"; phase rejected bash -c "exit 23"',
			"fixture",
			resources,
		],
		{ encoding: "utf8" },
	);
	// Then logging does not mask the failure.
	assert.equal(result.status, 23);
	assert.match(result.stdout, /phase=rejected seconds=\d+ exit=23/);
});

test("runtime rejects ambient execution without its owned CI contract", () => {
	// Given an ordinary shell, when invoking the real entrypoint.
	const result = spawnSync("bash", ["scripts/ci/run.sh", "run"], {
		encoding: "utf8",
		env: { ...process.env, GITHUB_ACTIONS: "false", CI_REHEARSAL: "false" },
	});
	// Then it fails before Docker resource acquisition.
	assert.equal(result.status, 2);
	assert.match(result.stderr, /use rehearse.mjs/);
});
