/**
 * Five-field cron expressions in local time: minute hour day-of-month month day-of-week. Each field takes `*`, a
 * number, a range `a-b`, a list `a,b`, and a step `* /n` or `a-b/n`. Day-of-week 0 and 7 are Sunday. As in classic
 * cron, when both day fields are restricted a day matches either one.
 */
export interface Cron {
	minutes: Set<number>;
	hours: Set<number>;
	days: Set<number>;
	months: Set<number>;
	weekdays: Set<number>;
	anyDay: boolean;
	anyWeekday: boolean;
}

const fields: Array<[name: string, min: number, max: number]> = [
	["minute", 0, 59],
	["hour", 0, 23],
	["day of month", 1, 31],
	["month", 1, 12],
	["day of week", 0, 7],
];

function parseField(text: string, [name, min, max]: (typeof fields)[number]): Set<number> {
	const values = new Set<number>();
	for (const part of text.split(",")) {
		const match = /^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/.exec(part);
		if (!match) throw new Error(`Invalid cron ${name}: ${part}`);
		const start = match[1] === "*" ? min : Number(match[2]);
		const end = match[1] === "*" ? max : match[3] !== undefined ? Number(match[3]) : match[4] ? max : start;
		const step = match[4] ? Number(match[4]) : 1;
		if (start < min || end > max || start > end || step < 1) throw new Error(`Invalid cron ${name}: ${part}`);
		for (let value = start; value <= end; value += step) values.add(value);
	}
	return values;
}

export function parseCron(expression: string): Cron {
	if (typeof expression !== "string" || expression.length > 100) throw new Error("cron must be a short expression");
	const parts = expression.trim().split(/\s+/);
	if (parts.length !== 5) throw new Error("cron needs 5 fields: minute hour day month weekday");
	const [minutes, hours, days, months, weekdays] = parts.map((part, index) => parseField(part, fields[index]!));
	if (weekdays!.delete(7)) weekdays!.add(0);
	return {
		minutes: minutes!,
		hours: hours!,
		days: days!,
		months: months!,
		weekdays: weekdays!,
		anyDay: parts[2] === "*",
		anyWeekday: parts[4] === "*",
	};
}

function dayMatches(cron: Cron, date: Date): boolean {
	if (!cron.months.has(date.getMonth() + 1)) return false;
	const day = cron.days.has(date.getDate());
	const weekday = cron.weekdays.has(date.getDay());
	if (cron.anyDay && cron.anyWeekday) return true;
	if (cron.anyDay) return weekday;
	if (cron.anyWeekday) return day;
	return day || weekday;
}

/** The first matching minute strictly after `after` (epoch ms), within about four years. */
export function nextCronTime(expression: string | Cron, after: number): number {
	const cron = typeof expression === "string" ? parseCron(expression) : expression;
	const date = new Date(after);
	date.setSeconds(0, 0);
	date.setMinutes(date.getMinutes() + 1);
	const limit = after + 4 * 366 * 86_400_000;
	while (date.getTime() <= limit) {
		if (!dayMatches(cron, date)) {
			date.setDate(date.getDate() + 1);
			date.setHours(0, 0, 0, 0);
			continue;
		}
		if (!cron.hours.has(date.getHours())) {
			date.setHours(date.getHours() + 1, 0, 0, 0);
			continue;
		}
		if (!cron.minutes.has(date.getMinutes())) {
			date.setMinutes(date.getMinutes() + 1, 0, 0);
			continue;
		}
		return date.getTime();
	}
	throw new Error("cron never matches");
}
