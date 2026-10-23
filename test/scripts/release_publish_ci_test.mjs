import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
	chmodSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import test from "node:test";
import {
	collectDevelopmentEvidence,
	developmentConclusion,
} from "../../scripts/verification/release-ci-evidence.mjs";
import { publicationCandidate } from "../../scripts/verification/release-publish-trigger.mjs";
import {
	completionEvent,
	repository,
	sha,
	successEvidence,
} from "./support/release_ci_fixture.mjs";

const base = `repos/${repository}/actions`;
const runList = `${base}/workflows/42/runs?head_sha=${sha}&event=push&per_page=100`;
const jobList = `${base}/runs/100/jobs?filter=all&per_page=100`;
const script = new URL(
	"../../scripts/verification/release-ci-evidence.mjs",
	import.meta.url,
).pathname;
const assess = (evidence) => developmentConclusion(sha, evidence, repository);
const responses = (evidence = successEvidence()) => ({
	[`${base}/workflows/development.yml`]: evidence.workflow,
	[runList]: [
		{
			total_count: evidence.run ? 1 : 0,
			workflow_runs: evidence.run ? [evidence.run] : [],
		},
	],
	[`${base}/runs/100`]: evidence.run,
	[jobList]: [{ total_count: evidence.jobs.length, jobs: evidence.jobs }],
});
const fromResponses =
	(values, calls = []) =>
	(endpoint, paginate = false) => {
		calls.push({ endpoint, paginate });
		assert.ok(
			Object.hasOwn(values, endpoint),
			`unexpected API request: ${endpoint}`,
		);
		return structuredClone(values[endpoint]);
	};

test("only the complete canonical workflow and required jobs authorize the exact revision", () => {
	assert.equal(assess(successEvidence()), "success");
	for (const mutate of [
		(e) => {
			e.sha = "b".repeat(40);
		},
		(e) => {
			e.repository = "other-org/sample-app";
		},
		(e) => {
			e.workflow.id = 43;
		},
		(e) => {
			e.workflow.path = ".github/workflows/other.yml";
		},
		(e) => {
			e.workflow.state = "disabled_manually";
		},
		(e) => {
			e.run.head_sha = "b".repeat(40);
		},
		(e) => {
			e.run.event = "pull_request";
		},
		(e) => {
			e.run.head_repository.full_name = "other-org/sample-app";
		},
		(e) => {
			e.jobs = e.jobs.slice(1);
		},
		(e) => {
			e.jobs[0].head_sha = "b".repeat(40);
		},
		(e) => {
			e.jobs[0].run_id = 99;
		},
		(e) => {
			e.jobs[0].run_attempt = 2;
		},
		(e) => {
			e.jobs.push({ ...e.jobs[0], id: 50 });
		},
	]) {
		const evidence = successEvidence();
		mutate(evidence);
		assert.throws(() => assess(evidence));
	}
});

test("missing or running CI defers, while unsuccessful runs and skipped jobs fail closed", () => {
	assert.equal(assess({ ...successEvidence(), run: null }), "pending");
	for (const state of ["queued", "in_progress", "waiting", "pending"])
		assert.equal(
			assess({
				...successEvidence(),
				run: { ...successEvidence().run, status: state, conclusion: null },
			}),
			"pending",
		);
	for (const conclusion of [
		"failure",
		"cancelled",
		"skipped",
		"neutral",
		"timed_out",
		"action_required",
		null,
	]) {
		const evidence = successEvidence();
		evidence.run.conclusion = conclusion;
		assert.equal(assess(evidence), "failure");
		const skippedJob = successEvidence();
		skippedJob.jobs[0].conclusion = conclusion;
		assert.equal(assess(skippedJob), "failure");
	}
});

test("failed-jobs reruns may reuse prior successful prerequisites but require the current attempt gate", () => {
	const evidence = successEvidence();
	evidence.run.run_attempt = 2;
	evidence.jobs.push(
		...evidence.jobs
			.slice(1)
			.map((job) => ({ ...job, id: job.id + 10, run_attempt: 2 })),
	);
	assert.equal(assess(evidence), "success");
	evidence.jobs = evidence.jobs.filter(
		(job) => !(job.name === "Development gate" && job.run_attempt === 2),
	);
	assert.equal(assess(evidence), "failure");
	evidence.jobs.push({ ...evidence.jobs[2], id: 30, run_attempt: 2 });
	evidence.jobs.push({
		...evidence.jobs[0],
		id: 31,
		run_attempt: 2,
		conclusion: "failure",
	});
	assert.equal(assess(evidence), "failure");
});

test("the collector uses workflow identity, paginated runs and all job attempts", () => {
	const evidence = successEvidence();
	const older = {
		...evidence.run,
		id: 99,
		run_number: 9,
		conclusion: "failure",
	};
	const values = responses(evidence);
	values[runList] = [
		{ total_count: 2, workflow_runs: [older] },
		{ total_count: 2, workflow_runs: [evidence.run] },
	];
	values[jobList] = [
		{ total_count: 3, jobs: evidence.jobs.slice(0, 1) },
		{ total_count: 3, jobs: evidence.jobs.slice(1) },
	];
	const calls = [];
	assert.deepEqual(
		collectDevelopmentEvidence(repository, sha, fromResponses(values, calls)),
		evidence,
	);
	assert.equal(
		calls.filter((call) => call.endpoint === runList && call.paginate).length,
		2,
	);
	assert.ok(calls.some((call) => call.endpoint === jobList && call.paginate));
});

test("stale success events cannot use an older passing run after a newer failed attempt", () => {
	const old = successEvidence();
	const event = completionEvent(old);
	const evidence = successEvidence();
	evidence.run.run_attempt = 2;
	evidence.run.conclusion = "failure";
	const selected = publicationCandidate(
		"workflow_run",
		event,
		[{ tag: "v1.2.3", sha }],
		[{ tag_name: "v1.2.3", draft: false, prerelease: false }],
		repository,
	);
	assert.equal(selected.revision, sha);
	assert.equal(
		assess(
			collectDevelopmentEvidence(
				repository,
				selected.revision,
				fromResponses(responses(evidence)),
			),
		),
		"failure",
	);
});

test("a newer pending run takes precedence over an earlier passing run on the same SHA", () => {
	const evidence = successEvidence();
	const newer = {
		...evidence.run,
		id: 101,
		run_number: 11,
		status: "queued",
		conclusion: null,
	};
	const values = responses(evidence);
	values[runList] = [{ total_count: 2, workflow_runs: [evidence.run, newer] }];
	values[`${base}/runs/101`] = newer;
	assert.equal(
		assess(collectDevelopmentEvidence(repository, sha, fromResponses(values))),
		"pending",
	);
});

test("incomplete pagination, identity changes and an intervening rerun cannot authorize publication", () => {
	for (const modify of [
		(values) => {
			values[runList][0].total_count = 2;
		},
		(values) => {
			values[runList][0].workflow_runs[0].event = "pull_request";
		},
		(values) => {
			values[`${base}/runs/100`].head_sha = "b".repeat(40);
		},
		(values) => {
			values[jobList][0].total_count = 4;
		},
	]) {
		const values = structuredClone(responses());
		modify(values);
		assert.throws(() =>
			collectDevelopmentEvidence(repository, sha, fromResponses(values)),
		);
	}
	let lists = 0;
	const request = fromResponses(responses());
	assert.throws(
		() =>
			collectDevelopmentEvidence(repository, sha, (endpoint, paginate) => {
				const value = request(endpoint, paginate);
				if (endpoint === runList && ++lists === 2)
					value[0].workflow_runs[0].run_attempt = 2;
				return value;
			}),
		/changed while/,
	);
});

function cliFixture(t, values) {
	const root = mkdtempSync(join(tmpdir(), "release-ci-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const bin = join(root, "bin");
	mkdirSync(bin);
	const executable = join(bin, "gh");
	writeFileSync(
		executable,
		`#!${process.execPath}\nimport { appendFileSync, readFileSync } from 'node:fs';
const args = process.argv.slice(2);
if (args[0] !== 'api') process.exit(3);
const endpoint = args.at(-1);
appendFileSync(process.env.API_CALLS, JSON.stringify(args) + '\\n');
const routes = JSON.parse(readFileSync(process.env.API_FIXTURE, 'utf8'));
if (!Object.hasOwn(routes, endpoint) || routes[endpoint].error) process.exit(2);
process.stdout.write(JSON.stringify(routes[endpoint]));\n`,
	);
	chmodSync(executable, 0o755);
	writeFileSync(join(root, "api.json"), JSON.stringify(values));
	const env = {
		...process.env,
		PATH: `${bin}${delimiter}${process.env.PATH}`,
		API_FIXTURE: join(root, "api.json"),
		API_CALLS: join(root, "calls.jsonl"),
		GITHUB_REPOSITORY: repository,
	};
	return { root, env };
}

test("actual evidence CLI accepts paginated API responses and preserves output on request failure", (t) => {
	const fixture = cliFixture(t, responses());
	const output = join(fixture.root, "evidence.json");
	const args = [script, repository, sha, output];
	const run = () =>
		spawnSync(process.execPath, args, { env: fixture.env, encoding: "utf8" });
	assert.equal(run().status, 0);
	assert.equal(assess(JSON.parse(readFileSync(output, "utf8"))), "success");
	const prior = readFileSync(output, "utf8");
	const failing = responses();
	failing[jobList] = { error: true };
	writeFileSync(fixture.env.API_FIXTURE, JSON.stringify(failing));
	const failed = run();
	assert.notEqual(failed.status, 0);
	assert.match(failed.stderr, /evidence request failed/);
	assert.equal(readFileSync(output, "utf8"), prior);
	assert.match(readFileSync(fixture.env.API_CALLS, "utf8"), /--paginate/);
	assert.equal(
		spawnSync(process.execPath, [script, "--help"], { encoding: "utf8" })
			.status,
		0,
	);
	assert.notEqual(
		spawnSync(process.execPath, [script, "invalid", sha, output], {
			env: fixture.env,
		}).status,
		0,
	);
});

test("the actual coordinator shell defers pending CI and rejects failed CI before registry access", (t) => {
	const workflow = readFileSync(
		new URL("../../.github/workflows/build.yml", import.meta.url),
		"utf8",
	);
	const start = workflow.indexOf(
		"      - name: Require verified revision and select monotonic release aliases\n",
	);
	const end = workflow.indexOf("\n  image:", start);
	const shell = workflow
		.slice(start, end)
		.split("        run: |\n")[1]
		.split("\n")
		.map((line) => line.replace(/^ {10}/, ""))
		.join("\n");
	for (const state of ["pending", "failure"]) {
		const evidence = successEvidence();
		if (state === "pending") evidence.run = null;
		else evidence.run.conclusion = "failure";
		const fixture = cliFixture(t, responses(evidence));
		const policy = join(fixture.root, ".release-policy/scripts/verification");
		mkdirSync(policy, { recursive: true });
		writeFileSync(
			join(policy, "release-ci-evidence.mjs"),
			readFileSync(script),
		);
		const output = join(fixture.root, "output");
		writeFileSync(output, "");
		const result = spawnSync("bash", ["-c", shell], {
			cwd: fixture.root,
			encoding: "utf8",
			env: {
				...fixture.env,
				REVISION: sha,
				RELEASE_TAG: "v1.2.3",
				RUNNER_TEMP: fixture.root,
				GITHUB_OUTPUT: output,
				GITHUB_STEP_SUMMARY: join(fixture.root, "summary"),
			},
		});
		assert.equal(result.status === 0, state === "pending", result.stderr);
		assert.equal(
			readFileSync(output, "utf8"),
			state === "pending" ? "ready=false\n" : "",
		);
		assert.doesNotMatch(
			readFileSync(fixture.env.API_CALLS, "utf8"),
			/releases\?/,
		);
	}
});
