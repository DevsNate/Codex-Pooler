export const repository = "example-org/sample-app";
export const sha = "a".repeat(40);

export function successEvidence(target = repository, revision = sha) {
	const workflow = {
		id: 42,
		name: "Development",
		path: ".github/workflows/development.yml",
		state: "active",
	};
	const run = {
		id: 100,
		run_attempt: 1,
		run_number: 10,
		workflow_id: workflow.id,
		name: workflow.name,
		path: workflow.path,
		event: "push",
		head_branch: "main",
		head_sha: revision,
		status: "completed",
		conclusion: "success",
		repository: { full_name: target },
		head_repository: { full_name: target },
	};
	const jobs = ["Quality", "Development image", "Development gate"].map(
		(name, index) => ({
			id: index + 1,
			name,
			run_id: run.id,
			run_attempt: run.run_attempt,
			head_sha: revision,
			status: "completed",
			conclusion: "success",
		}),
	);
	return { repository: target, sha: revision, workflow, run, jobs };
}

export function completionEvent(evidence = successEvidence()) {
	return {
		action: "completed",
		repository: { full_name: evidence.repository },
		workflow_run: evidence.run,
	};
}
