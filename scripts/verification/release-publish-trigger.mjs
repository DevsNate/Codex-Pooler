import { execFileSync } from "node:child_process";
import { appendFile, readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { trustedDevelopmentRun } from "./release-ci-evidence.mjs";
import { parseTag } from "./release-publish-guard.mjs";

const deferred = () => ({
	publish: false,
	reason: "published_release_not_found",
});

export function publicationCandidate(
	eventName,
	event,
	refs,
	releases,
	repository = "icoretech/codex-pooler",
) {
	let candidates;
	if (eventName === "workflow_run") {
		const run = event.workflow_run;
		if (
			event.action !== "completed" ||
			event.repository?.full_name !== repository ||
			!trustedDevelopmentRun(run, repository) ||
			run.status !== "completed" ||
			run.conclusion !== "success"
		)
			return { publish: false, reason: "irrelevant_workflow_run" };
		candidates = refs.filter((ref) => ref.sha === run.head_sha);
	} else {
		let tag;
		if (eventName === "workflow_dispatch")
			tag = event.inputs?.tag?.replace(/^refs\/tags\//, "");
		else if (eventName === "push" && event.ref?.startsWith("refs/tags/"))
			tag = event.ref.slice(10);
		else if (eventName === "release" && event.action === "published")
			tag = event.release?.tag_name;
		else throw new Error("unsupported publication event");
		parseTag(tag);
		candidates = refs.filter((ref) => ref.tag === tag);
		if (candidates.length !== 1 || !/^[a-f0-9]{40}$/.test(candidates[0].sha))
			throw new Error("release tag must resolve to one commit");
	}
	candidates = candidates.filter((ref) => {
		try {
			const version = parseTag(ref.tag);
			return releases.some(
				(release) =>
					release.tag_name === ref.tag &&
					!release.draft &&
					release.prerelease === version.prerelease,
			);
		} catch {
			return false;
		}
	});
	if (!candidates.length) return deferred();
	if (candidates.length !== 1)
		throw new Error("commit has multiple published release tags");
	return {
		publish: true,
		reason: "release_and_revision_selected",
		releaseTag: candidates[0].tag,
		revision: candidates[0].sha,
	};
}

async function main(args) {
	if (args.length === 1 && args[0] === "--help") {
		console.log(
			"usage: node release-publish-trigger.mjs EVENT_NAME EVENT_JSON RELEASES_JSON GITHUB_OUTPUT",
		);
		return;
	}
	if (args.length !== 4)
		throw new Error(
			"expected event name, event file, releases file and output",
		);
	const [eventName, eventFile, releaseFile, output] = args;
	const [event, releases] = await Promise.all([
		readFile(eventFile, "utf8").then(JSON.parse),
		readFile(releaseFile, "utf8").then(JSON.parse),
	]);
	const tags = execFileSync("git", ["tag", "--list"], { encoding: "utf8" })
		.trim()
		.split("\n")
		.filter(Boolean);
	const refs = tags.flatMap((tag) => {
		try {
			parseTag(tag);
			return [
				{
					tag,
					sha: execFileSync(
						"git",
						["rev-parse", "--verify", `refs/tags/${tag}^{commit}`],
						{ encoding: "utf8" },
					).trim(),
				},
			];
		} catch {
			return [];
		}
	});
	const result = publicationCandidate(
		eventName,
		event,
		refs,
		releases.flat(),
		process.env.GITHUB_REPOSITORY || "icoretech/codex-pooler",
	);
	const lines = [`publish=${result.publish}`, `reason=${result.reason}`];
	if (result.publish)
		lines.push(
			`release_tag=${result.releaseTag}`,
			`revision=${result.revision}`,
		);
	await appendFile(output, `${lines.join("\n")}\n`);
	console.log(JSON.stringify(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
	await main(process.argv.slice(2));
