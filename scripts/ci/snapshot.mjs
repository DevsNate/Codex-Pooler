import { execFileSync } from "node:child_process";
import {
	chmodSync,
	copyFileSync,
	lstatSync,
	mkdirSync,
	readFileSync,
	readlinkSync,
	realpathSync,
	symlinkSync,
	utimesSync,
	writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sourceIdentity } from "./source-identity.mjs";

export function snapshot(root, output) {
	const source = resolve(root);
	const destination = resolve(output);
	mkdirSync(destination, { recursive: false, mode: 0o700 });
	const tree = join(destination, "source");
	mkdirSync(tree, { mode: 0o700 });
	const revision = execFileSync("git", ["rev-parse", "HEAD"], {
		cwd: source,
		encoding: "utf8",
	}).trim();
	const paths = execFileSync(
		"git",
		["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
		{ cwd: source },
	)
		.toString()
		.split("\0")
		.filter(Boolean);
	for (const name of [...new Set(paths)].sort()) {
		if (
			name.split("/").includes(".git") ||
			name.startsWith("../") ||
			isAbsolute(name)
		)
			throw new Error(`unsafe source path: ${name}`);
		const input = join(source, name);
		let stat;
		try {
			stat = lstatSync(input);
		} catch (error) {
			if (error.code === "ENOENT") continue;
			throw error;
		}
		if (stat.isDirectory())
			throw new Error(
				`submodule/directory requires an explicit snapshot policy: ${name}`,
			);
		const target = join(tree, name);
		mkdirSync(dirname(target), { recursive: true });
		if (stat.isSymbolicLink()) {
			const link = readlinkSync(input);
			const resolved = relative(source, resolve(dirname(input), link));
			if (isAbsolute(link) || resolved === ".." || resolved.startsWith("../"))
				throw new Error(`source symlink escapes checkout: ${name}`);
			symlinkSync(link, target);
		} else if (stat.isFile()) {
			copyFileSync(input, target);
			const mode = stat.mode & 0o111 ? 0o755 : 0o644;
			chmodSync(target, mode);
			utimesSync(target, stat.atime, stat.mtime);
		} else throw new Error(`unsupported source file: ${name}`);
	}
	const receipt = { revision, ...sourceIdentity(tree) };
	writeFileSync(
		join(destination, "source.json"),
		`${JSON.stringify(receipt)}\n`,
		{ mode: 0o600 },
	);
	execFileSync(
		"tar",
		["-cf", join(destination, "source.tar"), "-C", tree, "."],
		{ env: { ...process.env, COPYFILE_DISABLE: "1" } },
	);
	return receipt;
}

export function verifySnapshot(root, receiptPath) {
	const receipt = JSON.parse(readFileSync(receiptPath, "utf8"));
	if (
		!receipt ||
		!/^[0-9a-f]{40}$/.test(receipt.revision) ||
		!/^[0-9a-f]{64}$/.test(receipt.contentHash) ||
		!Number.isInteger(receipt.files) ||
		receipt.files < 1
	)
		throw new Error("invalid snapshot receipt");
	const actual = sourceIdentity(root);
	if (
		actual.contentHash !== receipt.contentHash ||
		actual.files !== receipt.files
	)
		throw new Error("snapshot source differs from receipt");
	return receipt;
}

if (
	process.argv[1] &&
	realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
) {
	if (process.argv[2] === "--verify" && process.argv.length === 5) {
		console.log(
			JSON.stringify(verifySnapshot(process.argv[3], process.argv[4])),
		);
	} else if (process.argv.length !== 4) {
		console.error(
			"usage: node scripts/ci/snapshot.mjs CHECKOUT NEW_OUTPUT_DIRECTORY | --verify SOURCE_DIRECTORY RECEIPT",
		);
		process.exitCode = 2;
	} else
		console.log(JSON.stringify(snapshot(process.argv[2], process.argv[3])));
}
