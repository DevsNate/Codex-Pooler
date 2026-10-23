import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
	chmodSync,
	existsSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	statSync,
	symlinkSync,
	utimesSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { snapshot, verifySnapshot } from "../../scripts/ci/snapshot.mjs";

function repository(t) {
	const root = mkdtempSync(join(tmpdir(), "ci-snapshot-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const git = (...args) =>
		execFileSync("git", args, { cwd: root, stdio: "pipe" });
	git("init", "--quiet");
	git("config", "user.name", "CI Fixture");
	git("config", "user.email", "ci@example.com");
	writeFileSync(join(root, ".gitignore"), ".env\nresult*/\n");
	writeFileSync(join(root, "modified.txt"), "original\n");
	writeFileSync(join(root, "deleted.txt"), "remove me\n");
	git("add", ".");
	git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture");
	return root;
}

test("snapshot captures candidate additions, changes and deletions without ignored input", (t) => {
	// Given a dirty tree with one file of every change kind.
	const root = repository(t);
	writeFileSync(join(root, "modified.txt"), "candidate\n");
	writeFileSync(join(root, "added.sh"), "#!/bin/sh\nexit 0\n");
	chmodSync(join(root, "added.sh"), 0o755);
	rmSync(join(root, "deleted.txt"));
	writeFileSync(join(root, ".env"), "ignored fixture\n");
	// When frozen without a commit or push.
	const receipt = snapshot(root, join(root, "result"));
	// Then the archive represents the candidate and excludes deleted/private state.
	const names = execFileSync("tar", ["-tf", join(root, "result/source.tar")], {
		encoding: "utf8",
	});
	assert.match(names, /added.sh/);
	assert.doesNotMatch(names, /deleted.txt|\.env|\.git\//);
	assert.equal(
		readFileSync(join(root, "result/source/modified.txt"), "utf8"),
		"candidate\n",
	);
	assert.match(receipt.revision, /^[0-9a-f]{40}$/);
	assert.match(receipt.contentHash, /^[0-9a-f]{64}$/);
});

test("snapshot content identity changes for a same-commit candidate", (t) => {
	// Given the same revision with a changed working file.
	const root = repository(t);
	const original = snapshot(root, join(root, "result1"));
	writeFileSync(join(root, "modified.txt"), "changed\n");
	// When another candidate is frozen.
	const candidate = snapshot(root, join(root, "result2"));
	// Then the content identity distinguishes it from HEAD.
	assert.equal(candidate.revision, original.revision);
	assert.notEqual(candidate.contentHash, original.contentHash);
});

test("snapshot preserves source timestamps for incremental compilation", (t) => {
	// Given unchanged source with a stable old timestamp.
	const root = repository(t);
	const timestamp = new Date("2020-01-01T00:00:00Z");
	utimesSync(join(root, "modified.txt"), timestamp, timestamp);
	// When copied into a new candidate workspace.
	snapshot(root, join(root, "result"));
	// Then freezing alone does not make the compiler see a newer input.
	assert.equal(
		statSync(join(root, "result/source/modified.txt")).mtimeMs,
		timestamp.getTime(),
	);
});

test("snapshot refuses a symlink escaping its checkout", (t) => {
	// Given a link to data outside the source boundary.
	const root = repository(t);
	symlinkSync("../outside", join(root, "escaped"));
	// When freezing it, then no archive can be produced.
	assert.throws(() => snapshot(root, join(root, "result")), /symlink escapes/);
	assert.equal(existsSync(join(root, "result/source.tar")), false);
});

for (const mutation of ["modified", "missing", "extra"]) {
	test(`snapshot verification rejects ${mutation} files without Git metadata`, (t) => {
		// Given a frozen candidate with a valid receipt.
		const root = repository(t);
		const out = join(root, "result");
		snapshot(root, out);
		const tree = join(out, "source");
		assert.equal(verifySnapshot(tree, join(out, "source.json")).files, 3);
		// When its candidate bytes are changed after freezing.
		if (mutation === "missing") rmSync(join(tree, "modified.txt"));
		else
			writeFileSync(
				join(tree, mutation === "extra" ? "extra.txt" : "modified.txt"),
				"different\n",
			);
		// Then the exact-source contract fails.
		assert.throws(
			() => verifySnapshot(tree, join(out, "source.json")),
			/differs from receipt/,
		);
	});
}

test("rehearsal rejects a shell-bearing SSH target before execution", () => {
	// Given untrusted host syntax, when parsed by the real CLI.
	const result = spawnSync(
		process.execPath,
		[
			"scripts/ci/rehearse.mjs",
			"--out",
			"unused",
			"--host",
			"host;touch injected",
		],
		{ encoding: "utf8" },
	);
	// Then it fails before transport or filesystem acquisition.
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /invalid SSH host/);
});
