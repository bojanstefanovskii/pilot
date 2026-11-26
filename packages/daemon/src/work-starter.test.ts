import assert from "node:assert/strict";
import { test } from "node:test";
import type { SpawnRequest, TrackedItem, TrackedItemPatch } from "@pilot/protocol";
import { trackedItemLinker, WorkStarter } from "./work-starter.ts";

const item = (projectId = "p") => ({ id: "t1", projectId, kind: "linear" }) as unknown as TrackedItem;

function fixture(options: { projectId?: string; patchError?: Error } = {}) {
	const spawned: SpawnRequest[] = [];
	const storePatches: TrackedItemPatch[] = [];
	const registryPatches: Array<[string, TrackedItemPatch]> = [];
	const store = {
		require: async () => item(options.projectId),
		patch: async (_id: string, patch: TrackedItemPatch) => {
			storePatches.push(patch);
			return item();
		},
	};
	const registry = {
		patch: async (id: string, patch: TrackedItemPatch) => {
			if (options.patchError) throw options.patchError;
			registryPatches.push([id, patch]);
			return item();
		},
	};
	const starter = new WorkStarter({
		sessions: {
			spawn: async (request) => {
				spawned.push(request);
				return { id: "s1" };
			},
		},
		trackedItems: trackedItemLinker(store, registry),
	});
	return { starter, spawned, storePatches, registryPatches };
}

test("starting a chat from an item links it through the registry, which applies the external start", async () => {
	const { starter, spawned, storePatches, registryPatches } = fixture();
	const result = await starter.startChat({ spawn: { projectId: "p", message: "fix" }, trackedItemId: "t1" });
	assert.deepEqual(result, { sessionId: "s1" });
	assert.equal(spawned.length, 1);
	assert.deepEqual(registryPatches, [["t1", { sessionId: "s1", start: true }]]);
	assert.deepEqual(storePatches, []);
});

test("an item from another project is rejected before any chat starts", async () => {
	const { starter, spawned } = fixture({ projectId: "other" });
	await assert.rejects(
		starter.startChat({ spawn: { projectId: "p", message: "fix" }, trackedItemId: "t1" }),
		/Ticket must belong to this project/,
	);
	assert.equal(spawned.length, 0);
});

test("a failed link keeps the started chat and reports the error", async () => {
	const { starter } = fixture({ patchError: new Error("Sync Linear before starting") });
	const result = await starter.startChat({ spawn: { projectId: "p", message: "fix" }, trackedItemId: "t1" });
	assert.deepEqual(result, { sessionId: "s1", linkError: "Sync Linear before starting" });
});

test("a chat without an item starts without touching tracking", async () => {
	const { starter, registryPatches } = fixture();
	assert.deepEqual(await starter.startChat({ spawn: { projectId: "p", message: "fix" } }), { sessionId: "s1" });
	assert.deepEqual(registryPatches, []);
});
