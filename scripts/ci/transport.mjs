import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import { join } from "node:path";

export function createTransport(root, output, onChild) {
	return async (command, args, options = {}) => {
		const log = join(output, "transport.log");
		return await new Promise((resolveExit, reject) => {
			const child = spawn(command, args, {
				cwd: root,
				env: options.env ?? process.env,
				stdio: ["pipe", "pipe", "pipe"],
			});
			onChild(child);
			child.stdout.on("data", (data) => {
				appendFileSync(log, data);
				process.stdout.write(data);
			});
			child.stderr.on("data", (data) => {
				appendFileSync(log, data);
				process.stderr.write(data);
			});
			child.on("error", reject);
			child.on("close", (code) => {
				onChild(undefined);
				resolveExit(code ?? 130);
			});
			child.stdin.on("error", (error) => {
				if (error.code !== "EPIPE") reject(error);
			});
			child.stdin.end(options.input);
		});
	};
}
