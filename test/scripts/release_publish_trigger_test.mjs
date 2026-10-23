import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { publicationCandidate } from "../../scripts/verification/release-publish-trigger.mjs";
import {
	completionEvent,
	repository,
	sha,
	successEvidence,
} from "./support/release_ci_fixture.mjs";

const tag = "v1.2.3";
const refs = [{ tag, sha }];
const releases = [{ tag_name: tag, draft: false, prerelease: false }];
const passed = completionEvent();
const candidate = (eventName, event, tags = refs, published = releases) =>
	publicationCandidate(eventName, event, tags, published, repository);

test("release-first publication resumes on Development completion without a polling deadline", () => {
	assert.equal(
		candidate("workflow_dispatch", { inputs: { tag } }).revision,
		sha,
	);
	assert.equal(candidate("workflow_run", passed).releaseTag, tag);
});

test("CI-first publication waits for the release and resumes on dispatch or publication", () => {
	assert.equal(candidate("workflow_run", passed, refs, []).publish, false);
	for (const [eventName, event] of [
		["workflow_dispatch", { inputs: { tag } }],
		["release", { action: "published", release: releases[0] }],
		["push", { ref: `refs/tags/${tag}` }],
	])
		assert.equal(candidate(eventName, event).revision, sha);
});

test("failed, pending, foreign and unrelated workflow events cannot select publication", () => {
	for (const override of [
		{ status: "in_progress", conclusion: null },
		{ conclusion: "failure" },
		{ conclusion: "cancelled" },
		{ conclusion: "skipped" },
		{ name: "Other" },
		{ path: ".github/workflows/other.yml" },
		{ event: "pull_request" },
		{ event: "workflow_dispatch" },
		{ workflow_id: 0 },
		{ run_attempt: 0 },
		{ head_sha: "b".repeat(40) },
		{ head_sha: "invalid" },
		{ repository: { full_name: "other-org/sample-app" } },
		{ head_repository: { full_name: "other-org/sample-app" } },
	])
		assert.equal(
			candidate("workflow_run", {
				...passed,
				workflow_run: { ...passed.workflow_run, ...override },
			}).publish,
			false,
		);
	assert.equal(
		candidate("workflow_run", { ...passed, action: "requested" }).publish,
		false,
	);
	assert.equal(
		candidate("workflow_run", {
			...passed,
			repository: { full_name: "other-org/sample-app" },
		}).publish,
		false,
	);
	assert.equal(
		candidate("workflow_run", passed, refs, [{ ...releases[0], draft: true }])
			.publish,
		false,
	);
});

test("the completed run head SHA selects the release independently of the default-branch SHA", () => {
	assert.equal(
		candidate("workflow_run", { ...passed, sha: "b".repeat(40) }).revision,
		sha,
	);
});

test("duplicate success selects the same exact release; invalid or ambiguous tags are rejected", () => {
	for (let delivery = 0; delivery < 2; delivery += 1)
		assert.deepEqual(candidate("workflow_run", passed), {
			publish: true,
			reason: "release_and_revision_selected",
			releaseTag: tag,
			revision: sha,
		});
	for (const invalid of [
		"main",
		"v1.2",
		"v1.2.3-01",
		"v1.2.3+meta",
		"v1.2.3\nlatest",
		"v1.2.3\n",
	])
		assert.throws(() =>
			candidate("workflow_dispatch", { inputs: { tag: invalid } }),
		);
	assert.throws(
		() =>
			candidate(
				"workflow_run",
				passed,
				[...refs, { tag: "1.2.3", sha }],
				[...releases, { ...releases[0], tag_name: "1.2.3" }],
			),
		/multiple published/,
	);
});

test("CLI resolves real lightweight and annotated tags, and writes deferred outputs", (t) => {
	const root = mkdtempSync(join(tmpdir(), "release-trigger-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const git = (...args) =>
		execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
	git("init", "--quiet");
	git(
		"-c",
		"user.name=Example",
		"-c",
		"user.email=example@example.com",
		"commit",
		"--quiet",
		"--allow-empty",
		"-m",
		"initial",
	);
	const revision = git("rev-parse", "HEAD");
	git(
		"-c",
		"user.name=Example",
		"-c",
		"user.email=example@example.com",
		"tag",
		"-a",
		tag,
		"-m",
		"release",
	);
	git("tag", "not-a-release");
	writeFileSync(
		join(root, "event.json"),
		JSON.stringify(completionEvent(successEvidence(repository, revision))),
	);
	writeFileSync(join(root, "releases.json"), JSON.stringify([releases]));
	const script = new URL(
		"../../scripts/verification/release-publish-trigger.mjs",
		import.meta.url,
	).pathname;
	const args = [
		script,
		"workflow_run",
		join(root, "event.json"),
		join(root, "releases.json"),
		join(root, "output"),
	];
	const options = {
		cwd: root,
		encoding: "utf8",
		env: { ...process.env, GITHUB_REPOSITORY: repository },
	};
	assert.equal(
		JSON.parse(execFileSync(process.execPath, args, options)).revision,
		revision,
	);
	assert.match(readFileSync(join(root, "output"), "utf8"), /publish=true/);
	writeFileSync(join(root, "releases.json"), "[]");
	assert.equal(
		JSON.parse(execFileSync(process.execPath, args, options)).publish,
		false,
	);
	assert.match(
		readFileSync(join(root, "output"), "utf8"),
		/reason=published_release_not_found/,
	);
	assert.equal(
		spawnSync(process.execPath, [script, "--help"], options).status,
		0,
	);
});
