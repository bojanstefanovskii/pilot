import assert from "node:assert/strict";
import { test } from "node:test";
import type { Mission, SessionSummary } from "@pilot/protocol";
import { chatSummaryMessage, missionSummaryMessage, missionSummarySession } from "./work-summary.ts";

test("chat summary names its PRs, the skill reference and forbids code changes", () => {
	const session = {
		id: "s1",
		pullRequests: [{ number: 4, url: "https://github.com/o/r/pull/4", state: "merged" }],
	} as unknown as SessionSummary;
	const message = chatSummaryMessage(session);
	assert.match(message, /references\/summary\.md/);
	assert.match(message, /https:\/\/github\.com\/o\/r\/pull\/4/);
	assert.match(message, /Do not change code, commit or push/);
});

test("mission summary goes to the coordinator and asks to attach the artifact", () => {
	const mission = { id: "m1", title: "Billing", coordinatorSessionId: "c1" } as unknown as Mission;
	assert.equal(missionSummarySession(mission), "c1");
	assert.match(missionSummaryMessage(mission), /attach it to the mission/);
	assert.throws(() => missionSummarySession({ ...mission, coordinatorSessionId: undefined }), /no coordinator/);
});
