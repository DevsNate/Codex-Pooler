import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

const workflow = readFileSync(
	new URL("../../.github/workflows/pages.yml", import.meta.url),
	"utf8",
);

const condition = (job) => {
	const match = workflow.match(
		new RegExp(`^  ${job}:\\n    if: \\$\\{\\{ (.+) \\}\\}`, "m"),
	);
	assert.ok(match, `missing ${job} job condition`);
	return match[1];
};

const evaluates = (expression, github) =>
	runInNewContext(expression, {
		github,
		startsWith: (value, prefix) =>
			value.toLowerCase().startsWith(prefix.toLowerCase()),
	});

const pullRequest = (headRef, headRepository = "example-org/sample-app") => ({
	event_name: "pull_request",
	head_ref: headRef,
	repository: "example-org/sample-app",
	event: { pull_request: { head: { repo: { full_name: headRepository } } } },
});

for (const [name, github, build, deploy] of [
	[
		"release-please component PR",
		pullRequest("release-please--branches--main--components--sample-app"),
		false,
		false,
	],
	[
		"release-please notes PR",
		pullRequest(
			"release-please--branches--main--components--sample-app--release-notes",
		),
		false,
		false,
	],
	[
		"fork PR with a release-please branch name",
		pullRequest(
			"release-please--branches--main--components--sample-app",
			"external-contributor/sample-app",
		),
		true,
		false,
	],
	["ordinary docs PR", pullRequest("docs/update-guide"), true, false],
	["Renovate PR", pullRequest("renovate/docs-dependencies"), true, false],
	[
		"main release push",
		{ event_name: "push", ref: "refs/heads/main", head_ref: "" },
		true,
		true,
	],
	[
		"other branch push",
		{ event_name: "push", ref: "refs/heads/docs-update", head_ref: "" },
		true,
		false,
	],
	[
		"manual publication",
		{ event_name: "workflow_dispatch", ref: "refs/heads/main", head_ref: "" },
		true,
		true,
	],
]) {
	test(`Pages selects the intended jobs for a ${name}`, () => {
		assert.equal(evaluates(condition("build"), github), build);
		assert.equal(evaluates(condition("deploy"), github), deploy);
	});
}

test("Pages deployment requires the successful build and retains its artifact publication condition", () => {
	assert.match(workflow, / {2}deploy:\n[\s\S]*? {4}needs: build\n/);
	const upload = workflow.match(
		/- name: Upload Pages artifact\n {8}if: \$\{\{ (.+) \}\}/,
	);
	assert.ok(upload, "missing upload condition");
	assert.equal(upload[1], condition("deploy"));
});

for (const trigger of ["push", "pull_request"]) {
	test(`Pages policy changes execute their contract tests on ${trigger}`, () => {
		const policy = readFileSync(
			new URL("../../.github/workflows/release-policy.yml", import.meta.url),
			"utf8",
		);
		const paths = policy.match(
			new RegExp(`^  ${trigger}:\\n    paths:\\n((?:      - .+\\n)+)`, "m"),
		);
		assert.ok(paths, `missing ${trigger} paths`);
		for (const path of [
			".github/workflows/pages.yml",
			"test/scripts/pages_workflow_test.mjs",
		])
			assert.ok(
				paths[1].split("\n").includes(`      - '${path}'`),
				`missing ${path}`,
			);
		assert.match(policy, /node --test test\/scripts\/\*_test\.mjs/);
	});
}
