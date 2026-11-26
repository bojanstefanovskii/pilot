import assert from "node:assert/strict";
import { test } from "node:test";
import type { SessionPullRequest, SessionSummary } from "@pilot/protocol";
import {
	actionPullRequest,
	listMyPullRequests,
	listReviewRequests,
	listReviewThreads,
	pullRequestActionMessage,
	resolveReviewThreads,
	testPullRequestMessage,
} from "./pr-actions.ts";
import type { Runner } from "./workspaces.ts";

const pr = (number: number, state: SessionPullRequest["state"] = "open"): SessionPullRequest => ({
	number,
	url: `https://github.com/acme/app/pull/${number}`,
	title: `PR ${number}`,
	state,
	branch: `feat/${number}`,
	checkedAt: 1,
});
const session = (prs: SessionPullRequest[]) => ({ id: "s1", pullRequests: prs }) as unknown as SessionSummary;

test("actions target the chosen open PR, or the newest one", () => {
	assert.equal(actionPullRequest(session([pr(1), pr(2)])).number, 2);
	assert.equal(actionPullRequest(session([pr(1), pr(2)]), pr(1).url).number, 1);
	assert.throws(() => actionPullRequest(session([pr(3, "merged")])), /no open pull request/);
	const message = pullRequestActionMessage("resolve_comments", pr(4));
	assert.match(message, /pull\/4 \(branch feat\/4\)/);
	assert.match(message, /Never reply, comment, review or resolve threads/);
	assert.match(pullRequestActionMessage("rebase_main", pr(4)), /--force-with-lease/);
	assert.match(pullRequestActionMessage("fix_ci", pr(4)), /gh run view --log-failed/);
});

const threadsResponse = JSON.stringify({
	data: {
		repository: {
			pullRequest: {
				reviewThreads: {
					nodes: [
						{
							id: "T1",
							isResolved: false,
							isOutdated: false,
							path: "a.ts",
							line: 3,
							comments: { nodes: [{ body: "rename this", url: "u1", author: { login: "rev" } }] },
						},
						{ id: "T2", isResolved: true, isOutdated: false, comments: { nodes: [] } },
						{ id: "T3", isResolved: false, isOutdated: true, comments: { nodes: [] } },
					],
				},
			},
		},
	},
});

test("only unresolved, current threads are listed, and only those can be resolved", async () => {
	const calls: string[][] = [];
	const runner: Runner = async (_file, args) => {
		calls.push(args);
		return args.some((arg) => arg.includes("resolveReviewThread")) ? "{}" : threadsResponse;
	};
	const threads = await listReviewThreads(pr(7).url, "/tmp", runner);
	assert.deepEqual(threads, [{ id: "T1", path: "a.ts", line: 3, author: "rev", body: "rename this", url: "u1" }]);
	assert.ok(calls[0]!.includes("number=7"));

	await assert.rejects(resolveReviewThreads(pr(7).url, ["T2"], "/tmp", runner), /Not an unresolved thread/);
	assert.deepEqual(await resolveReviewThreads(pr(7).url, ["T1"], "/tmp", runner), ["T1"]);
	assert.ok(calls.at(-1)!.includes("id=T1"));
});

test("review requests come from the project's own repository, newest first, with their head branch", async () => {
	const calls: string[][] = [];
	const runner: Runner = async (file, args) => {
		calls.push([file, ...args]);
		if (file === "git") return "git@github.com:acme/app.git\n";
		if (args[0] === "search")
			return JSON.stringify([
				{
					number: 4,
					title: "Old",
					url: "https://github.com/acme/app/pull/4",
					author: { login: "a" },
					updatedAt: "2026-11-01T00:00:00Z",
				},
				{
					number: 5,
					title: "New",
					url: "https://github.com/acme/app/pull/5",
					author: { login: "b" },
					updatedAt: "2026-11-20T00:00:00Z",
				},
				{ number: 6, title: "Gone", url: "https://github.com/acme/app/pull/6", updatedAt: "2026-11-21T00:00:00Z" },
			]);
		const number = args[2];
		return number === "6" ? "{}" : JSON.stringify({ headRefName: `feat/${number}` });
	};
	const requests = await listReviewRequests("/repo", runner);
	assert.deepEqual(
		requests.map((request) => [request.number, request.branch]),
		[
			[5, "feat/5"],
			[4, "feat/4"],
		],
	);
	assert.ok(calls.some((call) => call.includes("--repo=acme/app") && call.includes("--review-requested=@me")));
	assert.match(testPullRequestMessage(requests[0]!), /Do not push, comment or review/);
});

test("my pull requests roll up state, review decision and checks", async () => {
	const runner: Runner = async (file, args) =>
		file === "git"
			? "git@github.com:acme/app.git"
			: JSON.stringify(
					[
						{
							number: 1,
							title: "A",
							url: "u1",
							state: "OPEN",
							isDraft: false,
							reviewDecision: "CHANGES_REQUESTED",
							headRefName: "a",
							updatedAt: "2026-11-24T10:00:00Z",
							statusCheckRollup: [{ status: "COMPLETED", conclusion: "FAILURE" }],
						},
						{
							number: 2,
							title: "B",
							url: "u2",
							state: "OPEN",
							isDraft: true,
							reviewDecision: "",
							headRefName: "b",
							updatedAt: "2026-11-23T10:00:00Z",
							statusCheckRollup: [{ status: "IN_PROGRESS", conclusion: "" }],
						},
						{
							number: 3,
							title: "C",
							url: "u3",
							state: "MERGED",
							isDraft: false,
							mergedAt: "2026-11-22T10:00:00Z",
							reviewDecision: "APPROVED",
							headRefName: "c",
							updatedAt: "2026-11-22T10:00:00Z",
							statusCheckRollup: [],
						},
					].filter((row) => (args.includes("--state=merged") ? row.state === "MERGED" : row.state === "OPEN")),
				);
	const prs = await listMyPullRequests("/repo", runner);
	assert.deepEqual(
		prs.map((pr) => [pr.number, pr.state, pr.reviewDecision, pr.checks]),
		[
			[1, "open", "changes_requested", "failing"],
			[2, "draft", undefined, "pending"],
			[3, "merged", "approved", undefined],
		],
	);
	assert.equal(prs[2]!.mergedAt, Date.parse("2026-11-22T10:00:00Z"));
});
