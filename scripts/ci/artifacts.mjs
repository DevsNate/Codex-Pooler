import { execFileSync } from "node:child_process";
import { appendFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export function collectArtifacts(connection, output, names) {
	let complete = true;
	for (const name of names) {
		try {
			const target = `${connection.remote}/output/${name}`;
			const quoted = `'${target.replaceAll("'", "'\\''")}'`;
			const data = execFileSync(
				"ssh",
				[...connection.ssh, connection.host, `cat ${quoted}`],
				{ maxBuffer: 128 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] },
			);
			if (data.length === 0) throw new Error(`empty artifact: ${name}`);
			writeFileSync(join(output, name), data, { mode: 0o600 });
		} catch (error) {
			appendFileSync(
				join(output, "transport.log"),
				`artifact unavailable: ${name}; exit=${error.status ?? "invalid"}\n`,
			);
			complete = false;
		}
	}
	return complete;
}
