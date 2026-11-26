import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
	TODAY_SECTIONS,
	type TodayItem,
	type TodayItemPatch,
	type TodayPage,
	type TodaySection,
} from "@pilot/protocol";

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const MAX_ITEMS = 30;
const MAX_LESSONS = 40;
const text = (value: unknown, max: number, field: string): string | undefined => {
	if (value === undefined || value === null) return undefined;
	if (typeof value !== "string" || value.length > max)
		throw new Error(`${field} must be text of at most ${max} characters`);
	return value.trim() || undefined;
};

/** The local calendar date, YYYY-MM-DD. */
export function localDate(now = new Date()): string {
	const pad = (value: number) => String(value).padStart(2, "0");
	return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

const empty = (date: string): TodayPage => ({
	date,
	updatedAt: 0,
	priorities: [],
	reviews: [],
	quickWins: [],
	waiting: [],
	lessons: [],
});

/**
 * The Today page, one JSON file per local day under `<home>/today`. Routines write sections through the
 * `today_write` tool; the user only marks items done or started. Lessons carry over from the previous page.
 */
export class TodayStore {
	private readonly dir: string;
	private readonly listeners = new Set<(page: TodayPage) => void>();
	private queue: Promise<unknown> = Promise.resolve();
	private readonly now: () => Date;

	constructor(home: string, now: () => Date = () => new Date()) {
		this.dir = join(home, "today");
		this.now = now;
	}

	onChange(listener: (page: TodayPage) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	async read(date = localDate(this.now())): Promise<TodayPage> {
		if (!DATE.test(date)) throw new Error("date must be YYYY-MM-DD");
		try {
			return JSON.parse(await readFile(join(this.dir, `${date}.json`), "utf8")) as TodayPage;
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
			return { ...empty(date), lessons: await this.carriedLessons(date) };
		}
	}

	/** A `today_write` call. Each section given replaces that section; done marks survive by item id. */
	write(args: Record<string, unknown>): Promise<TodayPage> {
		return this.serial(async () => {
			const date = text(args.date, 10, "date") ?? localDate(this.now());
			const page = await this.read(date);
			const next: TodayPage = { ...page, updatedAt: this.now().getTime() };
			for (const section of TODAY_SECTIONS) {
				if (args[section] === undefined) continue;
				const previous = new Map(page[section].map((item) => [item.id, item]));
				next[section] = validateItems(args[section], section).map((item) => {
					const old = previous.get(item.id);
					return {
						...item,
						...(old?.done ? { done: true } : {}),
						...(old?.sessionId ? { sessionId: old.sessionId } : {}),
					};
				});
			}
			const summary = text(args.summary, 1000, "summary");
			if (args.summary !== undefined) next.summary = summary;
			const wrap = text(args.wrap, 4000, "wrap");
			if (args.wrap !== undefined) next.wrap = wrap;
			if (args.lessons !== undefined) {
				if (!Array.isArray(args.lessons) || args.lessons.length > MAX_LESSONS)
					throw new Error(`lessons must be a list of at most ${MAX_LESSONS} lines`);
				next.lessons = args.lessons
					.map((line, index) => text(line, 300, `lessons[${index}]`))
					.filter(Boolean) as string[];
			}
			for (const key of Object.keys(next) as (keyof TodayPage)[]) if (next[key] === undefined) delete next[key];
			await this.save(next);
			return next;
		});
	}

	patchItem(id: string, patch: TodayItemPatch, date = localDate(this.now())): Promise<TodayItem> {
		return this.serial(async () => {
			const page = await this.read(date);
			for (const section of TODAY_SECTIONS) {
				const index = page[section].findIndex((item) => item.id === id);
				if (index < 0) continue;
				const item = { ...page[section][index]! };
				if (patch.done !== undefined) {
					if (typeof patch.done !== "boolean") throw new Error("done must be a boolean");
					if (patch.done) item.done = true;
					else delete item.done;
				}
				if (patch.sessionId !== undefined) item.sessionId = text(patch.sessionId, 64, "sessionId")!;
				page[section][index] = item;
				await this.save(page);
				return item;
			}
			throw new Error("Unknown Today item");
		});
	}

	private serial<T>(work: () => Promise<T>): Promise<T> {
		const next = this.queue.then(work, work);
		this.queue = next.catch(() => undefined);
		return next;
	}

	private async save(page: TodayPage): Promise<void> {
		await mkdir(this.dir, { recursive: true, mode: 0o700 });
		const file = join(this.dir, `${page.date}.json`);
		await writeFile(`${file}.tmp`, JSON.stringify(page), { mode: 0o600 });
		await rename(`${file}.tmp`, file);
		for (const listener of this.listeners) listener(page);
	}

	/** Lessons from the latest earlier page within two weeks. */
	private async carriedLessons(date: string): Promise<string[]> {
		const day = new Date(`${date}T12:00:00`);
		for (let back = 1; back <= 14; back++) {
			const earlier = localDate(new Date(day.getTime() - back * 86_400_000));
			try {
				const page = JSON.parse(await readFile(join(this.dir, `${earlier}.json`), "utf8")) as TodayPage;
				return page.lessons ?? [];
			} catch {}
		}
		return [];
	}
}

function validateItems(value: unknown, section: TodaySection): TodayItem[] {
	if (!Array.isArray(value) || value.length > MAX_ITEMS)
		throw new Error(`${section} must be a list of at most ${MAX_ITEMS} items`);
	const ids = new Set<string>();
	return value.map((raw, index) => {
		const at = `${section}[${index}]`;
		if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error(`${at} must be an object`);
		const item = raw as Record<string, unknown>;
		const title = text(item.title, 200, `${at}.title`);
		if (!title) throw new Error(`${at}.title is required`);
		const id =
			text(item.id, 80, `${at}.id`) ??
			title
				.toLowerCase()
				.replace(/[^a-z0-9]+/g, "-")
				.slice(0, 80);
		if (ids.has(id)) throw new Error(`${at}.id repeats ${id}`);
		ids.add(id);
		const url = text(item.url, 2000, `${at}.url`);
		if (url && !/^https:\/\//.test(url)) throw new Error(`${at}.url must be an https link`);
		const result: TodayItem = { id, title };
		const why = text(item.why, 400, `${at}.why`);
		const source = text(item.source, 80, `${at}.source`);
		const effort = text(item.effort, 20, `${at}.effort`);
		const prompt = text(item.prompt, 4000, `${at}.prompt`);
		if (why) result.why = why;
		if (url) result.url = url;
		if (source) result.source = source;
		if (effort) result.effort = effort;
		if (prompt) result.prompt = prompt;
		return result;
	});
}
