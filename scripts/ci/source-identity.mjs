import { createHash } from "node:crypto";
import {
	lstatSync,
	readdirSync,
	readFileSync,
	readlinkSync,
	realpathSync,
} from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function sourceIdentity(root) {
	const directory = resolve(root);
	const names = readdirSync(directory, { recursive: true, withFileTypes: true })
		.filter((entry) => !entry.isDirectory())
		.map((entry) => relative(directory, join(entry.parentPath, entry.name)))
		.sort();
	const entries = names.map((name) => {
		const target = join(directory, name);
		const stat = lstatSync(target);
		if (stat.isSymbolicLink()) {
			const link = readlinkSync(target);
			const resolved = relative(directory, resolve(target, "..", link));
			if (isAbsolute(link) || resolved === ".." || resolved.startsWith("../"))
				throw new Error(`source symlink escapes checkout: ${name}`);
			return {
				path: name,
				mode: "symlink",
				sha256: createHash("sha256").update(link).digest("hex"),
			};
		}
		if (!stat.isFile()) throw new Error(`unsupported source file: ${name}`);
		return {
			path: name,
			mode: stat.mode & 0o111 ? 0o755 : 0o644,
			sha256: createHash("sha256").update(readFileSync(target)).digest("hex"),
		};
	});
	return {
		contentHash: createHash("sha256")
			.update(JSON.stringify(entries))
			.digest("hex"),
		files: entries.length,
	};
}

if (
	process.argv[1] &&
	realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
) {
	if (process.argv.length !== 3) {
		console.error(
			"usage: node scripts/ci/source-identity.mjs SOURCE_DIRECTORY",
		);
		process.exitCode = 2;
	} else console.log(JSON.stringify(sourceIdentity(process.argv[2])));
}
