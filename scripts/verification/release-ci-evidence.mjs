import { execFileSync } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

export const developmentWorkflow = {
	name: "Development",
	path: ".github/workflows/development.yml",
	jobs: ["Quality", "Development image", "Development gate"],
};

const revisionPattern = /^[a-f0-9]{40}$/;
const repositoryPattern = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const positiveInteger = (value) => Number.isSafeInteger(value) && value > 0;

export function trustedDevelopmentRun(run, repository, workflowId) {
	return (
		positiveInteger(run?.id) &&
		positiveInteger(run?.run_attempt) &&
		positiveInteger(run?.run_number) &&
		positiveInteger(run?.workflow_id) &&
		(workflowId === undefined || run.workflow_id === workflowId) &&
		run.name === developmentWorkflow.name &&
		run.path === developmentWorkflow.path &&
		run.event === "push" &&
		typeof run.head_branch === "string" &&
		run.head_branch.length > 0 &&
		run.repository?.full_name === repository &&
		run.head_repository?.full_name === repository &&
		revisionPattern.test(run.head_sha ?? "")
	);
}

// Keep the raw, bounded authority fields so the publication guard can validate
// the receipt independently instead of trusting a precomputed success flag.
export function developmentConclusion(sha, evidence, repository) {
	if (
		!revisionPattern.test(sha ?? "") ||
		!repositoryPattern.test(repository ?? "") ||
		evidence?.sha !== sha ||
		evidence.repository !== repository
	)
		throw new Error(
			"CI evidence does not describe this repository and revision",
		);
	const workflow = evidence.workflow;
	if (
		!positiveInteger(workflow?.id) ||
		workflow.name !== developmentWorkflow.name ||
		workflow.path !== developmentWorkflow.path ||
		workflow.state !== "active"
	)
		throw new Error("required Development workflow identity is invalid");
	if (evidence.run === null) return "pending";
	const run = evidence.run;
	if (
		!trustedDevelopmentRun(run, repository, workflow.id) ||
		run.head_sha !== sha
	)
		throw new Error("required Development run identity is invalid");
	if (run.status !== "completed") return "pending";
	if (run.conclusion !== "success") return "failure";
	if (!Array.isArray(evidence.jobs))
		throw new Error("required Development job evidence is missing");
	for (const name of developmentWorkflow.jobs) {
		const jobs = evidence.jobs.filter((job) => job.name === name);
		if (
			!jobs.length ||
			jobs.some(
				(job) =>
					job.run_id !== run.id ||
					job.head_sha !== sha ||
					!positiveInteger(job.id) ||
					!positiveInteger(job.run_attempt) ||
					job.run_attempt > run.run_attempt,
			)
		)
			throw new Error(`missing or mismatched Development job: ${name}`);
		const latestAttempt = Math.max(...jobs.map((job) => job.run_attempt));
		const latest = jobs.filter((job) => job.run_attempt === latestAttempt);
		if (latest.length !== 1)
			throw new Error(`ambiguous Development job: ${name}`);
		const job = latest[0];
		if (
			job.status !== "completed" ||
			job.conclusion !== "success" ||
			(name === "Development gate" && latestAttempt !== run.run_attempt)
		)
			return "failure";
	}
	return "success";
}

function ghJSON(endpoint, paginate = false) {
	try {
		return JSON.parse(
			execFileSync(
				"gh",
				["api", ...(paginate ? ["--paginate", "--slurp"] : []), endpoint],
				{ encoding: "utf8", timeout: 60_000, maxBuffer: 8 * 1024 * 1024 },
			),
		);
	} catch {
		throw new Error("GitHub Actions evidence request failed");
	}
}

function pageItems(pages, key) {
	if (
		!Array.isArray(pages) ||
		!pages.length ||
		pages.some(
			(page) =>
				!Array.isArray(page?.[key]) ||
				!Number.isSafeInteger(page.total_count) ||
				page.total_count < 0,
		)
	)
		throw new Error(`invalid GitHub Actions ${key} pagination`);
	const items = pages.flatMap((page) => page[key]);
	if (pages.some((page) => page.total_count !== items.length))
		throw new Error(`incomplete or changing GitHub Actions ${key} inventory`);
	return items;
}

function runReceipt(run) {
	return Object.fromEntries(
		[
			"id",
			"run_attempt",
			"run_number",
			"workflow_id",
			"name",
			"path",
			"event",
			"head_branch",
			"head_sha",
			"status",
			"conclusion",
			"repository",
			"head_repository",
		].map((key) => [
			key,
			key.endsWith("repository")
				? { full_name: run[key]?.full_name }
				: run[key],
		]),
	);
}

export function collectDevelopmentEvidence(repository, sha, request = ghJSON) {
	if (!repositoryPattern.test(repository) || !revisionPattern.test(sha))
		throw new Error("expected repository owner/name and exact commit SHA");
	const base = `repos/${repository}/actions`;
	const source = request(`${base}/workflows/development.yml`);
	const workflow = Object.fromEntries(
		["id", "name", "path", "state"].map((key) => [key, source[key]]),
	);
	const evidence = { repository, sha, workflow, run: null, jobs: [] };
	developmentConclusion(sha, evidence, repository);
	const latestRun = () => {
		const runs = pageItems(
			request(
				`${base}/workflows/${workflow.id}/runs?head_sha=${sha}&event=push&per_page=100`,
				true,
			),
			"workflow_runs",
		);
		if (
			runs.some(
				(run) =>
					!trustedDevelopmentRun(run, repository, workflow.id) ||
					run.head_sha !== sha,
			) ||
			new Set(runs.map((run) => run.id)).size !== runs.length ||
			new Set(runs.map((run) => run.run_number)).size !== runs.length
		)
			throw new Error(
				"GitHub returned unrelated or ambiguous Development runs",
			);
		return runs.sort((left, right) => right.run_number - left.run_number)[0];
	};
	const selected = latestRun();
	if (!selected) return evidence;
	const run = request(`${base}/runs/${selected.id}`);
	if (
		!trustedDevelopmentRun(run, repository, workflow.id) ||
		run.head_sha !== sha ||
		run.id !== selected.id ||
		run.run_number !== selected.run_number ||
		run.run_attempt < selected.run_attempt
	)
		throw new Error("Development run changed identity during verification");
	evidence.run = runReceipt(run);
	if (run.status !== "completed" || run.conclusion !== "success")
		return evidence;
	// A failed-jobs rerun may reuse successful prerequisite jobs. Fetch every
	// attempt, choose each job's latest result, and require this attempt's gate.
	evidence.jobs = pageItems(
		request(`${base}/runs/${run.id}/jobs?filter=all&per_page=100`, true),
		"jobs",
	)
		.filter((job) => developmentWorkflow.jobs.includes(job.name))
		.map((job) =>
			Object.fromEntries(
				[
					"id",
					"name",
					"run_id",
					"run_attempt",
					"head_sha",
					"status",
					"conclusion",
				].map((key) => [key, job[key]]),
			),
		);
	const latest = latestRun();
	if (
		!latest ||
		latest.id !== run.id ||
		latest.run_attempt !== run.run_attempt ||
		latest.status !== run.status ||
		latest.conclusion !== run.conclusion
	)
		throw new Error("Development run changed while its jobs were verified");
	developmentConclusion(sha, evidence, repository);
	return evidence;
}

async function main(args) {
	if (args.length === 1 && args[0] === "--help") {
		console.log(
			"usage: node release-ci-evidence.mjs OWNER/REPO SHA EVIDENCE_JSON",
		);
		return;
	}
	if (args.length !== 3)
		throw new Error("expected repository, commit SHA and evidence output");
	const [repository, sha, output] = args;
	const evidence = collectDevelopmentEvidence(repository, sha);
	const state = developmentConclusion(sha, evidence, repository);
	await writeFile(output, JSON.stringify(evidence));
	console.log(state);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
	await main(process.argv.slice(2));
