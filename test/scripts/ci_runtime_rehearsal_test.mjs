import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
	copyFileSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

function fixture(t) {
	const root = mkdtempSync(join(tmpdir(), "ci-rehearsal-cli-"));
	const repository = join(root, "repo");
	const binary = join(root, "bin");
	const remoteFile = join(root, "remote");
	mkdirSync(join(repository, "scripts/ci"), { recursive: true });
	mkdirSync(join(repository, "scripts/verification"));
	mkdirSync(binary);
	t.after(() => {
		if (existsSync(remoteFile))
			rmSync(readFileSync(remoteFile, "utf8").trim(), {
				recursive: true,
				force: true,
			});
		rmSync(root, { recursive: true, force: true });
	});
	for (const name of [
		"rehearse.mjs",
		"snapshot.mjs",
		"source-identity.mjs",
		"transport.mjs",
		"artifacts.mjs",
	])
		copyFileSync(
			resolve("scripts/ci", name),
			join(repository, "scripts/ci", name),
		);
	writeFileSync(
		join(repository, "scripts/ci/run.sh"),
		`#!/usr/bin/env bash
set -eu
if [[ $1 == cleanup ]]; then exit "\${CLEANUP_EXIT:-0}"; fi
mkdir -p "$CI_OUTPUT_DIR"
cp "$CI_SOURCE_RECEIPT" "$CI_OUTPUT_DIR/source.json"
printf '{"exit":0,"cleanupExit":0}\\n' > "$CI_OUTPUT_DIR/receipt.json"
for name in run quality dialyzer; do printf 'fixture complete\\n' > "$CI_OUTPUT_DIR/$name.log"; done
exit "\${QUALITY_EXIT:-0}"
`,
	);
	writeFileSync(
		join(repository, "scripts/verification/development-image.sh"),
		`#!/usr/bin/env bash
set -eu
if [[ $1 == cleanup ]]; then exit "\${IMAGE_CLEANUP_EXIT:-0}"; fi
[[ -d "$CI_OUTPUT_DIR" ]] || exit 42
node "$CI_SOURCE_DIR/scripts/ci/snapshot.mjs" --verify "$CI_SOURCE_DIR" "$CI_SOURCE_RECEIPT" > "$CI_OUTPUT_DIR/image.json"
printf 'image fixture complete\\n' > "$CI_OUTPUT_DIR/image-build.log"
`,
	);
	writeFileSync(
		join(binary, "ssh"),
		`#!/usr/bin/env bash
set -eu
remote_command="\${@: -1}"
if [[ "$remote_command" == *"mktemp -d"* ]]; then
  allocated=$(bash -c "$remote_command")
  printf '%s\\n' "$allocated" > "$REMOTE_FILE"
  printf '%s\\n' "$allocated"
  exit
fi
if [[ -n \${FAIL_ARTIFACT:-} && "$remote_command" == cat\\ * && "$remote_command" == *"/\${FAIL_ARTIFACT}"* ]]; then exit 7; fi
exec bash -c "$remote_command"
`,
		{ mode: 0o755 },
	);
	const git = (...args) =>
		execFileSync("git", args, { cwd: repository, stdio: "pipe" });
	git("init", "--quiet");
	git("config", "user.name", "CI Fixture");
	git("config", "user.email", "ci@example.com");
	git("add", ".");
	git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture");
	const output = join(root, "output");
	return {
		output,
		remoteFile,
		runLocal: () =>
			spawnSync(
				process.execPath,
				["scripts/ci/rehearse.mjs", "--out", output, "--with-image"],
				{ cwd: repository, encoding: "utf8" },
			),
		run: (environment = {}, flags = []) =>
			spawnSync(
				process.execPath,
				[
					"scripts/ci/rehearse.mjs",
					"--host",
					"fixture",
					"--out",
					output,
					...flags,
				],
				{
					cwd: repository,
					encoding: "utf8",
					env: {
						...process.env,
						PATH: `${binary}:${process.env.PATH}`,
						REMOTE_FILE: remoteFile,
						...environment,
					},
				},
			),
	};
}

test("rehearsal preserves remote diagnostics when a completed run artifact cannot transfer", (t) => {
	// Given a successful remote run whose quality log transfer fails.
	const subject = fixture(t);
	// When the actual CLI completes its SSH sequence.
	const result = subject.run({ FAIL_ARTIFACT: "quality.log" });
	// Then transport failure is fatal and source/artifacts remain recoverable.
	assert.notEqual(result.status, 0);
	const recovery = JSON.parse(
		readFileSync(join(subject.output, "recovery.json"), "utf8"),
	);
	assert.equal(
		recovery.directory,
		readFileSync(subject.remoteFile, "utf8").trim(),
	);
	assert.equal(
		existsSync(join(recovery.directory, "output/quality.log")),
		true,
	);
	assert.match(result.stderr, /retained for recovery/);
});

test("rehearsal preserves remote diagnostics when owned resource cleanup fails", (t) => {
	// Given successful execution with a failing cleanup command.
	const subject = fixture(t);
	// When the real wrapper processes cleanup.
	const result = subject.run({ CLEANUP_EXIT: "9" });
	// Then it returns the failure and preserves the owned directory.
	assert.equal(result.status, 9);
	const recovery = JSON.parse(
		readFileSync(join(subject.output, "recovery.json"), "utf8"),
	);
	assert.equal(
		existsSync(join(recovery.directory, "output/receipt.json")),
		true,
	);
});

test("rehearsal releases remote directory after every required artifact transfers", (t) => {
	// Given successful execution, cleanup and transport.
	const subject = fixture(t);
	// When the real wrapper completes.
	const result = subject.run();
	// Then local artifacts are complete and the remote directory is released.
	assert.equal(result.status, 0, result.stderr);
	for (const name of [
		"source.json",
		"receipt.json",
		"run.log",
		"quality.log",
		"dialyzer.log",
	])
		assert.ok(readFileSync(join(subject.output, name)).length > 0);
	assert.equal(
		existsSync(readFileSync(subject.remoteFile, "utf8").trim()),
		false,
	);
	assert.equal(existsSync(join(subject.output, "recovery.json")), false);
});

test("image rehearsal receives the same verified frozen source as quality", (t) => {
	// Given a candidate requested with an image build.
	const subject = fixture(t);
	// When the real wrapper invokes quality then the image driver.
	const result = subject.run({}, ["--with-image"]);
	// Then the image's Git-free verification agrees with quality's source receipt.
	assert.equal(result.status, 0, result.stderr);
	assert.deepEqual(
		JSON.parse(readFileSync(join(subject.output, "image/image.json"), "utf8")),
		JSON.parse(readFileSync(join(subject.output, "source.json"), "utf8")),
	);
	assert.match(
		readFileSync(join(subject.output, "image/image-build.log"), "utf8"),
		/image fixture complete/,
	);
});

test("image rehearsal is withheld when quality fails", (t) => {
	// Given a quality failure with image rehearsal requested.
	const subject = fixture(t);
	// When the real wrapper processes that result.
	const result = subject.run({ QUALITY_EXIT: "23" }, ["--with-image"]);
	// Then the original failure propagates without producing an image receipt.
	assert.equal(result.status, 23);
	assert.equal(existsSync(join(subject.output, "image/image.json")), false);
});

test("local image rehearsal creates its output directory before invoking the driver", (t) => {
	// Given a driver that refuses a missing output directory.
	const subject = fixture(t);
	// When the actual local wrapper completes quality and requests an image.
	const result = subject.runLocal();
	// Then the image can write its receipt without preparing the caller's directory.
	assert.equal(result.status, 0, result.stderr);
	assert.ok(readFileSync(join(subject.output, "image/image.json")).length > 0);
});

test("image artifact transfer failure retains remote diagnostics", (t) => {
	// Given a successful image whose build log cannot be transferred.
	const subject = fixture(t);
	// When the real wrapper gathers both phases' artifacts.
	const result = subject.run({ FAIL_ARTIFACT: "image-build.log" }, [
		"--with-image",
	]);
	// Then it fails and retains the image build log at the recovery location.
	assert.notEqual(result.status, 0);
	const recovery = JSON.parse(
		readFileSync(join(subject.output, "recovery.json"), "utf8"),
	);
	assert.equal(
		existsSync(join(recovery.directory, "output/image/image-build.log")),
		true,
	);
});
