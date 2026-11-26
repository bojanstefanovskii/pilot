import type { SpawnRequest, TrackedItem, TrackedItemPatch } from "@pilot/protocol";

/** Reads and links tracked items. Linking with `start` must also apply the item's external start effect
 * (Linear In progress, Slack 👀), which only `SourceRegistry.patch` does; the bare store only links locally. */
export interface TrackedItemLinker {
	require(id: string): Promise<TrackedItem>;
	patch(id: string, patch: TrackedItemPatch): Promise<TrackedItem>;
}

/** Reads from the store and links through the source registry, so every caller gets the external start effect. */
export function trackedItemLinker(
	store: Pick<TrackedItemLinker, "require">,
	registry: Pick<TrackedItemLinker, "patch">,
): TrackedItemLinker {
	return { require: (id) => store.require(id), patch: (id, patch) => registry.patch(id, patch) };
}

export interface WorkStarterDeps {
	sessions: { spawn(request: SpawnRequest): Promise<{ id: string }> };
	trackedItems?: TrackedItemLinker;
}

export interface StartChatRequest {
	spawn: SpawnRequest;
	trackedItemId?: string;
}

/** Starts work from a ticket, a Slack message, a routine or a Today item: spawns the chat, then links the item
 * with its external start effect. A failed link never undoes the started chat; the caller gets the chat id. */
export class WorkStarter {
	private readonly deps: WorkStarterDeps;
	constructor(deps: WorkStarterDeps) {
		this.deps = deps;
	}

	async validateItem(id: string | undefined, projectId: string | undefined): Promise<TrackedItem | undefined> {
		if (id === undefined) return undefined;
		if (typeof id !== "string" || !id.trim() || id.length > 200)
			throw new Error("trackedItemId must be 1 to 200 characters");
		if (!this.deps.trackedItems) throw new Error("Tracking unavailable");
		const item = await this.deps.trackedItems.require(id);
		if (!projectId || item.projectId !== projectId) throw new Error("Ticket must belong to this project");
		return item;
	}

	async startChat(request: StartChatRequest): Promise<{ sessionId: string; linkError?: string }> {
		await this.validateItem(request.trackedItemId, request.spawn.projectId);
		const sessionId = (await this.deps.sessions.spawn(request.spawn)).id;
		if (request.trackedItemId === undefined) return { sessionId };
		try {
			await this.deps.trackedItems!.patch(request.trackedItemId, { sessionId, start: true });
			return { sessionId };
		} catch (error) {
			return { sessionId, linkError: (error instanceof Error ? error.message : String(error)).slice(0, 500) };
		}
	}
}
