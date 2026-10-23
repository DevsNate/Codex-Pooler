import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { collectArtifacts } from "./artifacts.mjs";
import { snapshot } from "./snapshot.mjs";
import { createTransport } from "./transport.mjs";

const { values } = parseArgs({
	options: {
		host: { type: "string" },
		out: { type: "string" },
		"sudo-password-stdin": { type: "boolean", default: false },
		sudo: { type: "boolean", default: false },
		"snapshot-only": { type: "boolean", default: false },
		"with-image": { type: "boolean", default: false },
		help: { type: "boolean", default: false },
	},
});
if (values.help) {
	console.log(
		"usage: node scripts/ci/rehearse.mjs --out NEW_DIRECTORY [--host SSH_ALIAS [--sudo | --sudo-password-stdin]] [--snapshot-only] [--with-image]",
	);
	process.exit(0);
}
if (!values.out) throw new Error("--out must name a new directory");
if (values.host && !/^[A-Za-z0-9][A-Za-z0-9_.@:-]*$/.test(values.host))
	throw new Error("invalid SSH host");
if ((values.sudo || values["sudo-password-stdin"]) && !values.host)
	throw new Error("sudo options require --host");
if (values.sudo && values["sudo-password-stdin"])
	throw new Error("choose one sudo option");
const output = resolve(values.out);
const root = resolve(import.meta.dirname, "../..");
mkdirSync(output, { recursive: false, mode: 0o700 });
const frozen = join(output, "snapshot");
const source = snapshot(root, frozen);
console.log(JSON.stringify(source));
if (values["snapshot-only"]) process.exit(0);
const runId = `rehearsal-${randomBytes(12).toString("hex")}`;
const password = values["sudo-password-stdin"]
	? readFileSync(0)
	: Buffer.alloc(0);
if (values["sudo-password-stdin"] && (!password.length || password.includes(0)))
	throw new Error("sudo password stdin is empty or invalid");
const ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"];
const quote = (text) => `'${text.replaceAll("'", "'\\''")}'`;
const sudo = values["sudo-password-stdin"]
	? "sudo -S -p '' "
	: values.sudo
		? "sudo -n "
		: "";
let interrupted = false;
let active;
const interrupt = () => {
	interrupted = true;
	active?.kill("SIGTERM");
};
process.on("SIGINT", interrupt);
process.on("SIGTERM", interrupt);
const execute = createTransport(root, output, (child) => {
	active = child;
});
let remote;
let exitCode = 1;
let preserveRemote = false;
let imageAttempted = false;
try {
	if (values.host) {
		const allocated = execFileSync(
			"ssh",
			[
				...ssh,
				values.host,
				"umask 077; mktemp -d /tmp/pooler-ci-rehearsal.XXXXXXXX",
			],
			{ encoding: "utf8" },
		).trim();
		if (!/^\/tmp\/pooler-ci-rehearsal\.[A-Za-z0-9]{8}$/.test(allocated))
			throw new Error("unexpected remote temporary directory");
		remote = allocated;
		for (const name of ["source.tar", "source.json"]) {
			execFileSync(
				"ssh",
				[...ssh, values.host, `cat > ${quote(`${remote}/${name}`)}`],
				{ input: readFileSync(join(frozen, name)) },
			);
		}
		execFileSync("ssh", [
			...ssh,
			values.host,
			`mkdir ${quote(`${remote}/source`)} ${quote(`${remote}/output`)} && tar -xf ${quote(`${remote}/source.tar`)} -C ${quote(`${remote}/source`)}`,
		]);
		const environment = `GITHUB_ACTIONS=false CI_REHEARSAL=true CI_RUN_ID=${runId} CI_OUTPUT_DIR=${quote(`${remote}/output`)} CI_SOURCE_ARCHIVE=${quote(`${remote}/source.tar`)} CI_SOURCE_RECEIPT=${quote(`${remote}/source.json`)}`;
		exitCode = await execute(
			"ssh",
			[
				...ssh,
				values.host,
				`${sudo}env ${environment} bash ${quote(`${remote}/source/scripts/ci/run.sh`)} run`,
			],
			{ input: password },
		);
	} else {
		exitCode = await execute(
			"bash",
			[join(frozen, "source/scripts/ci/run.sh"), "run"],
			{
				env: {
					...process.env,
					GITHUB_ACTIONS: "false",
					CI_REHEARSAL: "true",
					CI_RUN_ID: runId,
					CI_OUTPUT_DIR: output,
					CI_SOURCE_ARCHIVE: join(frozen, "source.tar"),
					CI_SOURCE_RECEIPT: join(frozen, "source.json"),
				},
			},
		);
	}
	if (values["with-image"] && exitCode === 0 && !interrupted) {
		imageAttempted = true;
		const imageSource = remote ? `${remote}/source` : join(frozen, "source");
		const imageReceipt = remote
			? `${remote}/source.json`
			: join(frozen, "source.json");
		const imageOutput = remote
			? `${remote}/output/image`
			: join(output, "image");
		if (remote && values.host) {
			execFileSync("ssh", [...ssh, values.host, `mkdir ${quote(imageOutput)}`]);
			const environment = `GITHUB_ACTIONS=false CI_REHEARSAL=true CI_RUN_ID=${runId} CI_SOURCE_DIR=${quote(imageSource)} CI_SOURCE_RECEIPT=${quote(imageReceipt)} CI_OUTPUT_DIR=${quote(imageOutput)}`;
			exitCode = await execute(
				"ssh",
				[
					...ssh,
					values.host,
					`${sudo}env ${environment} bash ${quote(`${imageSource}/scripts/verification/development-image.sh`)} rehearse`,
				],
				{ input: password },
			);
		} else {
			mkdirSync(imageOutput, { mode: 0o700 });
			exitCode = await execute(
				"bash",
				[
					join(imageSource, "scripts/verification/development-image.sh"),
					"rehearse",
				],
				{
					env: {
						...process.env,
						GITHUB_ACTIONS: "false",
						CI_REHEARSAL: "true",
						CI_RUN_ID: runId,
						CI_SOURCE_DIR: imageSource,
						CI_SOURCE_RECEIPT: imageReceipt,
						CI_OUTPUT_DIR: imageOutput,
					},
				},
			);
		}
	}
} finally {
	if (remote && values.host) {
		const cleanup = await execute(
			"ssh",
			[
				...ssh,
				values.host,
				`${sudo}env GITHUB_ACTIONS=false CI_REHEARSAL=true CI_RUN_ID=${runId} bash ${quote(`${remote}/source/scripts/ci/run.sh`)} cleanup`,
			],
			{ input: password },
		);
		if (cleanup !== 0) {
			preserveRemote = true;
			if (exitCode === 0) exitCode = cleanup;
		}
		if (imageAttempted) {
			const cleanupImage = await execute(
				"ssh",
				[
					...ssh,
					values.host,
					`${sudo}env GITHUB_ACTIONS=false CI_REHEARSAL=true CI_RUN_ID=${runId} CI_SOURCE_DIR=${quote(`${remote}/source`)} CI_SOURCE_RECEIPT=${quote(`${remote}/source.json`)} CI_OUTPUT_DIR=${quote(`${remote}/output/image`)} bash ${quote(`${remote}/source/scripts/verification/development-image.sh`)} cleanup`,
				],
				{ input: password },
			);
			if (cleanupImage !== 0) {
				preserveRemote = true;
				if (exitCode === 0) exitCode = cleanupImage;
			}
		}
		const artifacts = [
			"source.json",
			"receipt.json",
			"run.log",
			"quality.log",
			"dialyzer.log",
		];
		if (imageAttempted) {
			mkdirSync(join(output, "image"), { recursive: true, mode: 0o700 });
			artifacts.push("image/image-build.log", "image/image.json");
		}
		if (
			!collectArtifacts({ host: values.host, ssh, remote }, output, artifacts)
		) {
			preserveRemote = true;
			if (exitCode === 0) exitCode = 1;
		}
		if (preserveRemote) {
			const recovery = { host: values.host, directory: remote, run: runId };
			writeFileSync(
				join(output, "recovery.json"),
				`${JSON.stringify(recovery)}\n`,
				{ mode: 0o600 },
			);
			console.error(
				`rehearsal resources retained for recovery: ${values.host}:${remote}`,
			);
		} else
			execFileSync("ssh", [...ssh, values.host, `rm -rf -- ${quote(remote)}`]);
	}
	password.fill(0);
	process.off("SIGINT", interrupt);
	process.off("SIGTERM", interrupt);
	// Source bytes remain in the immutable tar; remove the expanded duplicate.
	rmSync(join(frozen, "source"), { recursive: true, force: true });
}
process.exitCode = interrupted ? 130 : exitCode;
