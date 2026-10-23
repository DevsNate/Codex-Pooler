import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

function fixture(t) {
	const root = mkdtempSync(join(tmpdir(), "ci-runtime-cache-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const binary = join(root, "docker");
	const inspection = join(root, "inspect.json");
	writeFileSync(
		binary,
		'#!/usr/bin/env bash\nset -eu\n[[ "$1 $2" == "image inspect" ]]\ncat "$INSPECTION"\n',
		{ mode: 0o755 },
	);
	return (image) => {
		writeFileSync(inspection, JSON.stringify([image]));
		return spawnSync(
			"bash",
			[
				"-c",
				'set -euo pipefail; source "$RESOURCES"; image_runtime_identity fixture',
			],
			{
				encoding: "utf8",
				env: {
					...process.env,
					RESOURCES: resolve("scripts/ci/resources.sh"),
					docker_command: binary,
					run_id: "rehearsal-cache",
					INSPECTION: inspection,
				},
			},
		);
	};
}

const original = {
	Id: "sha256:first-attested-index",
	Os: "linux",
	Architecture: "amd64",
	Created: "2026-01-01T00:00:00Z",
	Config: { Env: ["RUNTIME_VERSION=1"], WorkingDir: "/workspace" },
	RootFS: { Type: "layers", Layers: ["sha256:runtime-layer"] },
};

test("cache identity survives attestation-only image changes and JSON key ordering", (t) => {
	// Given two Docker inspections with the same executable configuration/filesystem.
	const identify = fixture(t);
	const first = identify(original);
	// When provenance/index identity and serialized key order change on the next build.
	const second = identify({
		...original,
		Id: "sha256:second-attested-index",
		Created: "2026-01-02T00:00:00Z",
		Config: { WorkingDir: "/workspace", Env: ["RUNTIME_VERSION=1"] },
		RootFS: { Layers: ["sha256:runtime-layer"], Type: "layers" },
	});
	// Then both successful commands return the same persistent cache identity.
	assert.equal(first.status, 0, first.stderr);
	assert.equal(second.status, 0, second.stderr);
	assert.match(first.stdout.trim(), /^[0-9a-f]{64}$/);
	assert.equal(second.stdout, first.stdout);
});

for (const changed of ["configuration", "filesystem", "architecture"]) {
	test(`cache identity changes when the executable ${changed} changes`, (t) => {
		// Given a cache identity for one runtime.
		const identify = fixture(t);
		const first = identify(original);
		// When a real runtime input changes, even if the top-level image ID stays the same.
		const image =
			changed === "architecture"
				? { ...original, Architecture: "arm64" }
				: changed === "configuration"
					? {
							...original,
							Config: { ...original.Config, Env: ["RUNTIME_VERSION=2"] },
						}
					: {
							...original,
							RootFS: {
								...original.RootFS,
								Layers: ["sha256:other-runtime-layer"],
							},
						};
		const second = identify(image);
		// Then its writable caches cannot be reused under the prior identity.
		assert.equal(first.status, 0, first.stderr);
		assert.equal(second.status, 0, second.stderr);
		assert.notEqual(second.stdout, first.stdout);
	});
}

test("invalid Docker inspection cannot produce a cache identity", (t) => {
	// Given an inspection without executable filesystem metadata.
	const identify = fixture(t);
	// When the actual identity helper consumes it.
	const result = identify({ Id: "sha256:incomplete" });
	// Then it fails instead of choosing a shared fallback cache.
	assert.notEqual(result.status, 0);
	assert.equal(result.stdout, "");
});
