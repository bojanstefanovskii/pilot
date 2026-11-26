import assert from "node:assert/strict";
import { test } from "node:test";
import { parseSlackPage, parseSlackThread, parseSlackThreadParent, parseSlackThreadReplies } from "./slack-format.ts";
import { parseSlackIdentity, parseSlackMentions } from "./slack-mentions.ts";
import { callUnifiedSlack, type UnifiedCall } from "./slack-unified.ts";
import { decodeMcpResult, slackAlreadyReacted } from "./source-mcp.ts";
import { parseMyChannels, parseSearch } from "./tracking-lookup.ts";

const json = (value: unknown) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });
const C = "C051S4T56P4";
const parent = {
	ts: "1795517518.103169",
	text: "hi <@U09MRKB7Q1H> pls exchange the SL",
	user: "U09MRMA1G67",
	user_name: "Eva",
	thread_ts: "1795517518.103169",
	reply_count: 2,
	files: [{ name: "CyberDirekt.docx", title: "CyberDirekt Sideletter" }],
	attachments: [":book: Sideletters Overview"],
};
const replies = [
	{
		ts: "1795517600.000001",
		text: "on it",
		user: "U09MRKB7Q1H",
		user_name: "Bojan Stefanovski",
		thread_ts: parent.ts,
	},
	{ ts: "1795517700.000002", text: "thanks!", user: "U09MRMA1G67", user_name: "Eva", thread_ts: parent.ts },
];
const channels = {
	channels: [
		{ id: C, name: "product-underwriting", is_member: true },
		{ id: "C999", name: "random", is_member: false },
	],
};

function fake(): { call: UnifiedCall; calls: Array<[string, Record<string, unknown>]> } {
	const calls: Array<[string, Record<string, unknown>]> = [];
	const call: UnifiedCall = async (name, args) => {
		calls.push([name, args]);
		if (name === "SLACK_LIST_CHANNELS") return json(channels);
		if (name === "SLACK_READ_MESSAGES" && args.thread_ts) {
			const all = [parent, ...replies].filter((message) => !args.oldest || message.ts > String(args.oldest));
			return json({ messages: all.slice(0, Number(args.limit)), has_more: false, next_cursor: null });
		}
		if (name === "SLACK_READ_MESSAGES") return json({ messages: [parent], has_more: true, next_cursor: "abc123" });
		if (name === "SLACK_SEARCH_MESSAGES" && args.query === "from:me")
			return json({ matches: [{ ts: "1.000001", user: "U09MRKB7Q1H", user_name: "bojan.stefanovski", text: "x" }] });
		if (name === "SLACK_SEARCH_MESSAGES")
			return json({
				matches: [
					{
						ts: parent.ts,
						text: parent.text,
						user: parent.user,
						user_name: "eva",
						permalink: `https://stoikio.slack.com/archives/${C}/p${parent.ts.replace(".", "")}?thread_ts=${parent.ts}`,
						channel: { id: C, name: "product-underwriting" },
					},
				],
			});
		if (name === "SLACK_GET_REACTIONS")
			return json({ reactions: [{ name: "white_check_mark", count: 1, users: ["Linear"] }], ts: parent.ts });
		if (name === "SLACK_ADD_REACTION")
			return { content: [{ type: "text", text: "Error: already_reacted" }], isError: true };
		if (name === "SLACK_POST_MESSAGE") return json({ posted: false, where: "dm" });
		throw new Error(`unexpected ${name}`);
	};
	return { call, calls };
}

test("history and threads render in the dedicated format the existing parsers accept", async () => {
	const { call } = fake();
	const history = await callUnifiedSlack(
		"history",
		{ channel_id: C, oldest: "1", limit: 50, response_format: "detailed" },
		call,
	);
	const page = parseSlackPage(history.value!, 50);
	assert.equal(page.channel, C);
	assert.equal(page.name, "product-underwriting");
	assert.equal(page.next, "abc123");
	assert.equal(page.messages[0]!.replies, 2);
	assert.match(page.messages[0]!.text, /<@U09MRKB7Q1H> pls exchange the SL/);
	assert.match(page.messages[0]!.text, /Attachment: :book: Sideletters Overview/);

	const thread = parseSlackThread(
		(await callUnifiedSlack("thread", { channel_id: C, message_ts: parent.ts, limit: 20 }, call)).value!,
		parent.ts,
		20,
	);
	assert.deepEqual(
		thread.messages.map((message) => message.ts),
		[parent.ts, ...replies.map((reply) => reply.ts)],
	);
	assert.equal(
		parseSlackThreadParent(
			(await callUnifiedSlack("thread", { channel_id: C, message_ts: parent.ts, limit: 1 }, call)).value!,
			parent.ts,
		).author,
		"Eva",
	);

	const newer = parseSlackThreadReplies(
		(
			await callUnifiedSlack(
				"thread",
				{ channel_id: C, message_ts: parent.ts, oldest: replies[0]!.ts, limit: 10 },
				call,
			)
		).value!,
		parent.ts,
		10,
	);
	assert.deepEqual(
		newer.replies.map((reply) => [reply.ts, reply.userId]),
		[[replies[1]!.ts, "U09MRMA1G67"]],
	);
	const none = parseSlackThreadReplies(
		(
			await callUnifiedSlack(
				"thread",
				{ channel_id: C, message_ts: parent.ts, oldest: replies[1]!.ts, limit: 10 },
				call,
			)
		).value!,
		parent.ts,
		10,
	);
	assert.deepEqual(none, { replies: [], more: false });
});

test("identity, mentions, channels, reactions and the approved reply map to unified tools", async () => {
	const { call, calls } = fake();
	assert.deepEqual(
		parseSlackIdentity((await callUnifiedSlack("profile", { response_format: "detailed" }, call)).value!),
		{
			id: "U09MRKB7Q1H",
			username: "bojan.stefanovski",
		},
	);
	const mentions = parseSlackMentions(
		(
			await callUnifiedSlack(
				"mentionsPrivate",
				{ keywords: ["@underwriting"], filters: `in:<#${C}>`, limit: 20 },
				call,
			)
		).value!,
		C,
		"product-underwriting",
		20,
	);
	assert.equal(mentions.messages[0]!.threadTs, parent.ts);
	assert.deepEqual(parseMyChannels((await callUnifiedSlack("myChannels", { limit: 200 }, call)).value!).items, [
		{ id: C, name: "product-underwriting", private: false },
	]);
	assert.deepEqual(
		parseSearch((await callUnifiedSlack("searchChannels", { keywords: ["random"], limit: 20 }, call)).value!).items,
		[{ id: "C999", name: "random", private: false }],
	);
	const reactions = await callUnifiedSlack("reactions", { channel_id: C, message_ts: parent.ts }, call);
	assert.deepEqual(decodeMcpResult(reactions.result!, "reactions"), { present: true });
	await assert.rejects(
		callUnifiedSlack("startSlack", { channel_id: C, message_ts: parent.ts, emoji: "eyes" }, call),
		(error) => slackAlreadyReacted(error),
	);
	assert.deepEqual(
		(await callUnifiedSlack("replySlack", { channel_id: C, thread_ts: parent.ts, message: "On it" }, call)).value,
		{
			ok: true,
			posted: false,
		},
	);
	assert.deepEqual(calls.find(([name]) => name === "SLACK_POST_MESSAGE")?.[1], {
		channel: C,
		thread_ts: parent.ts,
		text: "On it",
	});
	await assert.rejects(callUnifiedSlack("removeSlackEyes", {}, call), /not available through unified-mcp/);
});
