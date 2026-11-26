import type { SpawnRequest } from "./index.ts";

/**
 * on_back is sleep after save/edit, then a full wake followed by reachability ("When I'm back"). Triggers are
 * one-shot, except an `at` trigger with a `cron` recurrence, which re-arms at its next time after each run.
 */
export type ScheduleTrigger = "at" | "on_wake" | "on_online" | "on_back";
export type ScheduleTarget =
	| {
			kind: "chat";
			spawn: SpawnRequest;
			/** Bound to the created chat on dispatch. */
			trackedItemId?: string;
	  }
	| { kind: "message"; sessionId: string; message: string };
export type ScheduleState = "pending" | "dispatching" | "fired" | "failed" | "cancelled";

/** POST /api/schedules. Omitted trigger defaults to on_back. */
export interface ScheduleRequest {
	title?: string;
	trigger?: ScheduleTrigger;
	/** Epoch milliseconds. Required only for at; overdue times fire when online. Defaults to the cron's next time. */
	at?: number;
	/** Five-field cron in local time (minute hour day month weekday), for a recurring routine. Implies trigger at. */
	cron?: string;
	target: ScheduleTarget;
}
/** PATCH /api/schedules/:id. Only pending items are editable. Target replacement is complete. */
export interface SchedulePatch {
	title?: string;
	trigger?: ScheduleTrigger;
	at?: number;
	/** null stops the recurrence. */
	cron?: string | null;
	target?: ScheduleTarget;
	/** Optional optimistic concurrency guard against a stale editor. */
	expectedRevision?: number;
}
export interface ScheduledItem {
	id: string;
	revision: number;
	title: string;
	projectId?: string;
	/** Removed triggers are a non-executable tombstone on cancelled records. */
	trigger: ScheduleTrigger | "removed";
	at?: number;
	/** Recurring routine: stays pending, with `at` its next run. `firedAt`, `sessionId` and `error` describe the last. */
	cron?: string;
	/** Completed runs of a recurring routine. */
	runs?: number;
	target: ScheduleTarget;
	state: ScheduleState;
	createdAt: number;
	updatedAt: number;
	/** Persisted so a full wake while offline survives a restart. Requires sleepObserved. */
	wakeObserved?: boolean;
	/** A sleep after the last save/edit. Dark wakes do not consume this latch. */
	sleepObserved?: boolean;
	claimedAt?: number;
	firedAt?: number;
	/** Created chat, or target of a follow-up. */
	sessionId?: string;
	error?: string;
}
/** Full bounded index on connect and after changes. Terminal rows retained until DELETE. */
export interface SchedulesMessage {
	type: "schedules";
	schedules: ScheduledItem[];
}
