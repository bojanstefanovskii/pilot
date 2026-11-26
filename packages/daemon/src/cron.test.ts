import assert from "node:assert/strict";
import { test } from "node:test";
import { nextCronTime, parseCron } from "./cron.ts";

const local = (y: number, mo: number, d: number, h = 0, mi = 0) => new Date(y, mo - 1, d, h, mi).getTime();

test("weekday mornings, steps, lists and Sunday as 7", () => {
	// Friday 2026-11-27 09:00 → next weekday 09:00 is Monday 11-30.
	assert.equal(nextCronTime("0 9 * * 1-5", local(2026, 11, 27, 9, 0)), local(2026, 11, 30, 9, 0));
	assert.equal(nextCronTime("*/15 * * * *", local(2026, 11, 27, 9, 7)), local(2026, 11, 27, 9, 15));
	assert.equal(nextCronTime("30 12,18 * * *", local(2026, 11, 27, 12, 30)), local(2026, 11, 27, 18, 30));
	assert.equal(nextCronTime("0 8 * * 7", local(2026, 11, 27)), local(2026, 11, 29, 8, 0));
	assert.equal(nextCronTime("0 0 1 * *", local(2026, 11, 27)), local(2026, 12, 1));
	assert.equal(nextCronTime("0 0 29 2 *", local(2026, 3, 1)), local(2028, 2, 29));
});

test("invalid expressions are rejected", () => {
	assert.throws(() => parseCron("0 9 * *"), /5 fields/);
	assert.throws(() => parseCron("61 * * * *"), /minute/);
	assert.throws(() => parseCron("0 9 * * mon"), /day of week/);
	assert.throws(() => nextCronTime("0 0 31 2 *", 0), /never matches/);
});
