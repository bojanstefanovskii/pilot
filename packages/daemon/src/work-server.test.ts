import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { SessionSummary, SpawnRequest, TrackedItem, TrackedItemPatch } from "@pilot/protocol";
import type { ModelCatalog } from "./models.ts";
import { ProjectStore } from "./projects.ts";
import { createDaemonServer } from "./server.ts";
import type { SessionManager } from "./sessions.ts";
import type { SourceRegistry } from "./sources.ts";
import type { TerminalManager } from "./terminals.ts";
import { TodayStore } from "./today.ts";

test("POST /api/work/chat starts the chat and links the item through the registry", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "pilot-work-api-"));
	const projects = new ProjectStore(home);
	await projects.load();
	const project = await projects.create({ path: home, workspace: "direct" });
	const spawned: SpawnRequest[] = [];
	const summary: SessionSummary = {
		id: "s1",
		title: "Started",
		projectId: project.id,
		cwd: home,
		state: "working",
		createdAt: 1,
		updatedAt: 1,
	};
	const sessions = {
		setWorkspaceProcessGuard() {},
		list: () => [summary],
		get: (id: string) => (id === "s1" ? summary : undefined),
		onChange: () => () => {},
		onArtifactsChanged: () => () => {},
		spawn: async (request: SpawnRequest) => {
			spawned.push(request);
			return summary;
		},
	} as unknown as SessionManager;
	const patches: Array<[string, TrackedItemPatch]> = [];
	let linkFails = false;
	const tracking = {
		onChange: () => () => {},
		requireItem: async (id: string) => ({ id, projectId: id === "foreign" ? "other" : project.id }) as TrackedItem,
		patch: async (id: string, patch: TrackedItemPatch) => {
			if (linkFails) throw new Error("Sync Linear before starting");
			patches.push([id, patch]);
			return { id } as TrackedItem;
		},
	} as unknown as SourceRegistry;
	const server = createDaemonServer(
		{ home, host: "127.0.0.1", port: 0 },
		sessions,
		projects,
		{} as ModelCatalog,
		{ isRunning: () => false } as unknown as TerminalManager,
		undefined,
		undefined,
		undefined,
		undefined,
		tracking,
	);
	server.listen(0, "127.0.0.1");
	await once(server, "listening");
	const port = (server.address() as AddressInfo).port;
	t.after(async () => {
		server.closeAllConnections();
		await new Promise<void>((resolve) => server.close(() => resolve()));
		await rm(home, { recursive: true, force: true });
	});
	const post = (body: unknown) =>
		fetch(`http://127.0.0.1:${port}/api/work/chat`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(body),
		});

	const started = await post({ spawn: { projectId: project.id, message: "fix" }, trackedItemId: "t1" });
	assert.equal(started.status, 201);
	assert.deepEqual(await started.json(), { session: summary });
	assert.deepEqual(patches, [["t1", { sessionId: "s1", start: true }]]);

	const foreign = await post({ spawn: { projectId: project.id, message: "fix" }, trackedItemId: "foreign" });
	assert.equal(foreign.status, 400);
	assert.equal(spawned.length, 1, "a foreign item never starts a chat");

	linkFails = true;
	const unlinked = await post({ spawn: { projectId: project.id, message: "fix" }, trackedItemId: "t1" });
	assert.equal(unlinked.status, 201);
	assert.deepEqual(await unlinked.json(), { session: summary, linkError: "Sync Linear before starting" });

	assert.equal((await post({})).status, 400);
});

test("POST /api/sessions/:id/pull-request-actions sends the agent the action for the chat's open PR", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "pilot-pr-actions-api-"));
	const projects = new ProjectStore(home);
	await projects.load();
	const summary = {
		id: "11111111-1111-4111-8111-111111111111",
		title: "PR chat",
		cwd: home,
		state: "idle",
		createdAt: 1,
		updatedAt: 1,
		pullRequests: [
			{ number: 9, url: "https://github.com/acme/app/pull/9", title: "x", state: "open", branch: "b", checkedAt: 1 },
		],
	} as unknown as SessionSummary;
	const sent: string[] = [];
	const sessions = {
		setWorkspaceProcessGuard() {},
		list: () => [summary],
		get: (id: string) => (id === summary.id ? summary : undefined),
		onChange: () => () => {},
		onArtifactsChanged: () => () => {},
		send: async (_id: string, message: string) => {
			sent.push(message);
		},
	} as unknown as SessionManager;
	const server = createDaemonServer(
		{ home, host: "127.0.0.1", port: 0 },
		sessions,
		projects,
		{} as ModelCatalog,
		{ isRunning: () => false } as unknown as TerminalManager,
	);
	server.listen(0, "127.0.0.1");
	await once(server, "listening");
	const port = (server.address() as AddressInfo).port;
	t.after(async () => {
		server.closeAllConnections();
		await new Promise<void>((resolve) => server.close(() => resolve()));
		await rm(home, { recursive: true, force: true });
	});
	const post = (body: unknown) =>
		fetch(`http://127.0.0.1:${port}/api/sessions/${summary.id}/pull-request-actions`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(body),
		});
	assert.equal((await post({ action: "fix_ci" })).status, 202);
	assert.match(sent[0]!, /Check the CI of PR https:\/\/github.com\/acme\/app\/pull\/9/);
	assert.equal((await post({ action: "deploy" })).status, 400);
	assert.equal((await post({ action: "rebase_main", url: "https://github.com/acme/app/pull/1" })).status, 409);
	assert.equal(sent.length, 1);
});

test("GET /api/today reads the day's page and PATCH marks an item done", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "pilot-today-api-"));
	const projects = new ProjectStore(home);
	await projects.load();
	const store = new TodayStore(home);
	await store.write({ date: "2026-11-24", priorities: [{ id: "a", title: "Fix renewal" }] });
	const sessions = {
		setWorkspaceProcessGuard() {},
		list: () => [],
		get: () => undefined,
		onChange: () => () => {},
		onArtifactsChanged: () => () => {},
		todayStore: store,
	} as unknown as SessionManager;
	const server = createDaemonServer(
		{ home, host: "127.0.0.1", port: 0 },
		sessions,
		projects,
		{} as ModelCatalog,
		{ isRunning: () => false } as unknown as TerminalManager,
	);
	server.listen(0, "127.0.0.1");
	await once(server, "listening");
	const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/api/today`;
	t.after(async () => {
		server.closeAllConnections();
		await new Promise<void>((resolve) => server.close(() => resolve()));
		await rm(home, { recursive: true, force: true });
	});
	const page = await (await fetch(`${base}?date=2026-11-24`)).json();
	assert.equal(page.priorities[0].title, "Fix renewal");
	const patch = (id: string) =>
		fetch(`${base}/items/${id}?date=2026-11-24`, {
			method: "PATCH",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ done: true }),
		});
	assert.equal((await patch("a")).status, 200);
	assert.equal((await store.read("2026-11-24")).priorities[0]!.done, true);
	assert.equal((await patch("missing")).status, 400);
});

test("POST /api/sessions/:id/fix-it starts a Build chat from an Ask investigation's conclusion", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "pilot-fix-it-api-"));
	const projects = new ProjectStore(home);
	await projects.load();
	const ask = {
		id: "22222222-2222-4222-8222-222222222222",
		title: "Renewal email missing",
		mode: "ask",
		projectId: "p1",
	};
	const build = { id: "33333333-3333-4333-8333-333333333333", mode: "build", projectId: "p1" };
	const spawned: SpawnRequest[] = [];
	let conclusion: string | undefined = "Root cause: the cron skips paused policies.";
	const sessions = {
		setWorkspaceProcessGuard() {},
		list: () => [],
		get: (id: string) => (id === ask.id ? ask : id === build.id ? build : undefined),
		onChange: () => () => {},
		onArtifactsChanged: () => () => {},
		lastAssistantReply: async () => conclusion,
		spawn: async (request: SpawnRequest) => {
			spawned.push(request);
			return { id: "new" };
		},
	} as unknown as SessionManager;
	const server = createDaemonServer(
		{ home, host: "127.0.0.1", port: 0 },
		sessions,
		projects,
		{} as ModelCatalog,
		{ isRunning: () => false } as unknown as TerminalManager,
	);
	server.listen(0, "127.0.0.1");
	await once(server, "listening");
	const port = (server.address() as AddressInfo).port;
	t.after(async () => {
		server.closeAllConnections();
		await new Promise<void>((resolve) => server.close(() => resolve()));
		await rm(home, { recursive: true, force: true });
	});
	const fix = (id: string, body: unknown = {}) =>
		fetch(`http://127.0.0.1:${port}/api/sessions/${id}/fix-it`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(body),
		});
	assert.equal((await fix(ask.id, { kind: "quick" })).status, 201);
	assert.equal(spawned[0]!.mode, "build");
	assert.equal(spawned[0]!.kind, "quick");
	assert.equal(spawned[0]!.projectId, "p1");
	assert.match(spawned[0]!.message, /cron skips paused policies[\s\S]*failing test first/);
	assert.equal((await fix(build.id)).status, 409);
	conclusion = undefined;
	assert.equal((await fix(ask.id)).status, 409);
});
