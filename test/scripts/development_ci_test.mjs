import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
	new URL("../../.github/workflows/development.yml", import.meta.url),
	"utf8",
);

function job(id) {
	const start = workflow.indexOf(`\n  ${id}:\n`);
	assert.ok(start >= 0, `missing ${id} job`);
	const rest = workflow.slice(start + 1);
	const end = rest.slice(3).search(/\n {2}[a-z]+:\n/);
	return end < 0 ? rest : rest.slice(0, end + 3);
}

test("development only receives branch pushes and excludes both release automation branches", () => {
	const triggers = workflow.split("\npermissions:")[0];
	assert.match(triggers, /^name: Development\n/);
	assert.match(triggers, /\n {2}push:\n {4}branches:\n {6}- '\*\*'/);
	assert.match(
		triggers,
		/'!release-please--branches--main--components--codex-pooler'/,
	);
	assert.match(
		triggers,
		/'!release-please--branches--main--components--codex-pooler--release-notes'/,
	);
	assert.deepEqual(
		[...triggers.matchAll(/^ {6}- '([^']+)'$/gm)].map((match) => match[1]),
		[
			"**",
			"!release-please--branches--main--components--codex-pooler",
			"!release-please--branches--main--components--codex-pooler--release-notes",
		],
	);
	assert.doesNotMatch(workflow, /github\.(actor|triggering_actor)/);
	assert.doesNotMatch(
		triggers,
		/pull_request|workflow_dispatch|workflow_run|repository_dispatch|tags:/,
	);
	assert.doesNotMatch(
		workflow,
		/continue-on-error:\s*true|cancel-in-progress:\s*true/,
	);
	assert.match(
		workflow,
		/group: development-\$\{\{ github\.ref \}\}\n\s+queue: max\n\s+cancel-in-progress: false/,
	);
});

test("the canonical workflow requires quality, image and aggregate jobs on the native runner", () => {
	for (const [id, name] of [
		["quality", "Quality"],
		["image", "Development image"],
		["gate", "Development gate"],
	]) {
		assert.match(job(id), new RegExp(`name: ${name}\\n`));
		assert.match(job(id), /github\.repository == 'icoretech\/codex-pooler'/);
		assert.match(job(id), /runs-on: \[self-hosted, Linux, X64, ci-amd64\]/);
	}
	assert.match(job("image"), /needs: quality\n/);
	assert.match(job("gate"), /needs: \[quality, image\]\n/);
	assert.match(job("gate"), /if: always\(\) &&/);
	assert.match(job("quality"), /run: bash scripts\/ci\/run\.sh run/);
	assert.match(
		job("quality"),
		/if: always\(\)\n\s+run: bash scripts\/ci\/run\.sh cleanup/,
	);
	assert.equal((workflow.match(/persist-credentials: false/g) || []).length, 2);
	assert.match(workflow, /permissions:\n {2}contents: read\n/);
	assert.doesNotMatch(
		workflow,
		/contents: write|packages: write|id-token: write/,
	);
});

test("only the main publishing step receives registry secrets and artifacts survive cleanup", () => {
	const quality = job("quality");
	const qualityArtifact = quality.slice(
		quality.indexOf("- name: Save quality evidence"),
	);
	const qualityPaths = qualityArtifact
		.split("          path: |\n")[1]
		.split("          if-no-files-found:")[0]
		.trim()
		.split("\n")
		.map((line) => line.trim());
	assert.deepEqual(
		qualityPaths,
		["source.json", "receipt.json", "*.log"].map(
			(name) =>
				`tmp/ci-results/github-\${{ github.run_id }}-\${{ github.run_attempt }}/${name}`,
		),
	);
	assert.doesNotMatch(qualityArtifact, /snapshot|source\.tar|\/source\//);
	const image = job("image");
	const branch = image.slice(
		image.indexOf("- name: Build development branch"),
		image.indexOf("- name: Build and publish main"),
	);
	assert.match(branch, /if: github\.ref != 'refs\/heads\/main'/);
	assert.doesNotMatch(branch, /secrets\./);
	const publish = image.slice(
		image.indexOf("- name: Build and publish main"),
		image.indexOf("- name: Remove owned image"),
	);
	assert.match(publish, /if: github\.ref == 'refs\/heads\/main'/);
	assert.match(publish, /secrets\.ICORETECH_REGISTRY_USER/);
	assert.match(publish, /secrets\.ICORETECH_REGISTRY_PASSWORD/);
	assert.match(
		image,
		/if: always\(\)\n\s+run: bash scripts\/verification\/development-image\.sh cleanup/,
	);
	assert.match(
		image,
		/path: tmp\/ci-results\/github-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}\/image\*/,
	);
	assert.ok(
		image.indexOf("Remove owned image") < image.indexOf("Save image evidence"),
	);
});

test("the actual aggregate shell rejects every failed, skipped, cancelled or incomplete prerequisite", () => {
	const script = job("gate")
		.split("        run: |\n")[1]
		.split("\n")
		.map((line) => line.replace(/^ {10}/, ""))
		.join("\n");
	for (const quality of ["success", "failure", "cancelled", "skipped", ""]) {
		for (const image of ["success", "failure", "cancelled", "skipped", ""]) {
			const result = spawnSync("bash", ["-c", script], {
				env: { ...process.env, QUALITY_RESULT: quality, IMAGE_RESULT: image },
				encoding: "utf8",
			});
			assert.equal(
				result.status,
				quality === "success" && image === "success" ? 0 : 1,
				`${quality}/${image}: ${result.stderr}`,
			);
		}
	}
});
