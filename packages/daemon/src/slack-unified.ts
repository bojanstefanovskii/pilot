/**
 * Slack through the Stoik unified MCP (`CALL_TOOL` with `SLACK_*` tools), for users whose pi has no dedicated
 * `slack` server login. Each logical tracking tool maps to a fixed unified tool, and the unified JSON is rendered in
 * the dedicated server's formatted-text contract, so the existing parsers (slack-format, slack-mentions,
 * tracking-lookup) and their fail-closed checks stay the single source of truth.
 */
import type { TrackingJson } from "@pilot/protocol";
import { SourceToolError, sourceToolFailure } from "./source-mcp.ts";

type McpResult = { content?: Array<{ type: string; text?: string }>; isError?: boolean; structuredContent?: unknown };
/** Calls the unified server's CALL_TOOL with one allowlisted inner tool. */
export type UnifiedCall = (name: UnifiedSlackTool, args: Record<string, unknown>) => Promise<McpResult>;

/** The only unified tools tracking may reach. Writes are reactions and the user's approved thread reply. */
export const UNIFIED_SLACK_TOOLS = [
	"SLACK_READ_MESSAGES",
	"SLACK_SEARCH_MESSAGES",
	"SLACK_LIST_CHANNELS",
	"SLACK_GET_REACTIONS",
	"SLACK_ADD_REACTION",
	"SLACK_POST_MESSAGE",
] as const;
export type UnifiedSlackTool = (typeof UNIFIED_SLACK_TOOLS)[number];

/** Logical tracking tools this adapter serves. Eyes removal keeps its own configured route. */
export const UNIFIED_SLACK_LOGICAL = [
	"history",
	"thread",
	"profile",
	"mentionsPrivate",
	"reactions",
	"startSlack",
	"doneSlack",
	"replySlack",
	"myChannels",
	"searchChannels",
] as const;

interface UnifiedMessage {
	ts: string;
	text?: string;
	user?: string;
	user_name?: string;
	thread_ts?: string;
	reply_count?: number;
	attachments?: string[];
	files?: Array<{ name?: string; title?: string }>;
	permalink?: string;
	channel?: { id?: string; name?: string };
}

/** Inner tool JSON, or a SourceToolError that never carries provider text. */
export function unifiedJson(result: McpResult): Record<string, unknown> {
	const text = (result.content ?? [])
		.filter((block) => block.type === "text")
		.map((block) => block.text ?? "")
		.join("\n");
	if (Buffer.byteLength(text) > 512 * 1024) throw new SourceToolError("Slack response too large");
	if (result.isError || /^(?:Error|Invalid arguments)\b/.test(text.trim())) {
		// already_reacted is idempotent success for reaction writes; callers match it on the message.
		if (/\balready_reacted\b/.test(text)) throw new Error("already_reacted");
		throw new SourceToolError(
			"Slack tool returned an error",
			/not_authed|invalid_auth|missing_scope|not authorized/i.test(text)
				? "access_denied"
				: sourceToolFailure(result),
		);
	}
	let value: unknown = result.structuredContent;
	if (value === undefined) {
		try {
			value = JSON.parse(text);
		} catch {
			throw new SourceToolError("Slack tool did not return JSON");
		}
	}
	if (!value || typeof value !== "object" || Array.isArray(value))
		throw new SourceToolError("Unexpected Slack response");
	const object = value as Record<string, unknown>;
	if (object.ok === false || typeof object.error === "string") {
		if (object.error === "already_reacted") throw new Error("already_reacted");
		throw new SourceToolError(
			"Slack tool returned an error",
			/not_authed|invalid_auth|missing_scope/.test(String(object.error)) ? "access_denied" : "tool_error",
		);
	}
	return object;
}

const messagesOf = (value: Record<string, unknown>, field = "messages"): UnifiedMessage[] => {
	const list = value[field];
	if (!Array.isArray(list) || list.length > 1000) throw new SourceToolError("Unexpected Slack messages");
	return list.filter(
		(message): message is UnifiedMessage =>
			!!message && typeof message === "object" && typeof (message as UnifiedMessage).ts === "string",
	);
};

const time = (ts: string) => new Date(Number(ts.split(".")[0]) * 1000).toISOString();
const from = (message: UnifiedMessage) =>
	`${(message.user_name ?? "unknown").replace(/\s+/g, " ").slice(0, 80)}${message.user && /^[UWB][A-Z0-9]{1,40}$/.test(message.user) ? ` (${message.user})` : ""}`;

/** Message body in the dedicated format: text, then metadata lines, then attachment blocks. */
function body(message: UnifiedMessage, thread: boolean): string {
	const lines = [(message.text ?? "").replace(/\r\n/g, "\n")];
	const files = (message.files ?? []).map((file) => file.title ?? file.name).filter(Boolean);
	if (files.length) lines.push(`Files: ${files.join(", ")}`);
	if (thread && (message.reply_count ?? 0) > 0)
		lines.push(`Thread: ${message.reply_count} ${message.reply_count === 1 ? "reply" : "replies"}`);
	for (const attachment of message.attachments ?? [])
		lines.push(`Attachment: ${String(attachment).replace(/\r\n/g, "\n")}`);
	return lines.join("\n");
}

const cursorOf = (value: Record<string, unknown>) =>
	value.has_more === true && typeof value.next_cursor === "string" && value.next_cursor
		? value.next_cursor
		: undefined;

async function channelName(call: UnifiedCall, id: string): Promise<string> {
	try {
		const value = unifiedJson(await call("SLACK_LIST_CHANNELS", { types: ["public_channels", "private_channels"] }));
		const list = (value.channels ?? value.conversations) as Array<{ id?: string; name?: string }> | undefined;
		return list?.find((channel) => channel.id === id)?.name ?? id;
	} catch {
		return id;
	}
}

/** Runs one logical tracking tool through unified-mcp and returns the dedicated server's shape. */
export async function callUnifiedSlack(
	logicalTool: string,
	args: Record<string, unknown>,
	call: UnifiedCall,
): Promise<{ value?: TrackingJson; result?: McpResult }> {
	switch (logicalTool) {
		case "history": {
			const channel = String(args.channel_id);
			const value = unifiedJson(
				await call("SLACK_READ_MESSAGES", {
					channel,
					limit: args.limit ?? 50,
					...(args.oldest ? { oldest: args.oldest } : {}),
					...(args.latest ? { latest: args.latest } : {}),
					...(args.cursor ? { cursor: args.cursor } : {}),
				}),
			);
			const name = await channelName(call, channel);
			const messages = messagesOf(value)
				.map(
					(message) => `=== Message from ${from(message)} ===\nMessage TS: ${message.ts}\n${body(message, true)}`,
				)
				.join("\n\n");
			const next = cursorOf(value);
			return {
				value: {
					messages: `Channel: #${name} (${channel})\n\n${messages}`,
					pagination_info: next
						? `There are more messages available. To view the next page, use cursor: \`${next}\``
						: "There are no more messages available.",
				},
			};
		}
		case "thread": {
			const channel = String(args.channel_id);
			const parentTs = String(args.message_ts);
			const value = unifiedJson(
				await call("SLACK_READ_MESSAGES", {
					channel,
					thread_ts: parentTs,
					limit: Math.min(Number(args.limit ?? 50) + 1, 1000),
					...(args.oldest ? { oldest: args.oldest } : {}),
					...(args.cursor ? { cursor: args.cursor } : {}),
				}),
			);
			let messages = messagesOf(value);
			let parent = messages.find((message) => message.ts === parentTs);
			if (!parent) {
				// A read from `oldest` can leave the parent out; the dedicated format always leads with it.
				parent = messagesOf(
					unifiedJson(await call("SLACK_READ_MESSAGES", { channel, thread_ts: parentTs, limit: 1 })),
				).find((message) => message.ts === parentTs);
				if (!parent) throw new SourceToolError("Slack thread parent missing");
			}
			const limit = Number(args.limit ?? 50);
			messages = messages.filter(
				(message) => message.ts !== parentTs && (!args.oldest || message.ts > String(args.oldest)),
			);
			const replies = messages.slice(0, limit);
			const render = (message: UnifiedMessage) =>
				`From: ${from(message)}\nTime: ${time(message.ts)}\nMessage TS: ${message.ts}\n${body(message, false)}`;
			const next = cursorOf(value) ?? (messages.length > replies.length ? "more" : undefined);
			const text = replies.length
				? `=== THREAD PARENT MESSAGE ===\n${render(parent)}\n=== THREAD REPLIES (${replies.length} total) ===\n${replies
						.map((reply, index) => `--- Reply ${index + 1} of ${replies.length} ---\n${render(reply)}`)
						.join("\n")}`
				: `=== THREAD PARENT MESSAGE ===\n${render(parent)}\n\n${args.oldest ? "No thread messages." : "=== THREAD REPLIES (0 total) ==="}`;
			return {
				value: {
					messages: text,
					pagination_info: next
						? `There are more messages in this thread. To view the next page, use cursor: \`${next}\``
						: "There are no more messages in this thread.",
				},
			};
		}
		case "profile": {
			// No identity tool: the user's own latest message carries their ID and handle.
			const value = unifiedJson(await call("SLACK_SEARCH_MESSAGES", { query: "from:me", limit: 1 }));
			const me = messagesOf(value, "matches")[0];
			if (!me?.user || !me.user_name) throw new SourceToolError("Slack identity unavailable");
			return { value: { result: `User ID: ${me.user}\nUsername: @${me.user_name}` } };
		}
		case "mentionsPrivate": {
			const keywords = Array.isArray(args.keywords) ? args.keywords.join(" ") : "";
			const query = `${String(args.filters ?? "")} ${keywords}`.trim();
			const value = unifiedJson(
				await call("SLACK_SEARCH_MESSAGES", { query, limit: Math.min(Number(args.limit ?? 20), 100) }),
			);
			const matches = messagesOf(value, "matches");
			const results = matches.length
				? `# Search Results for: ${query}\n\n${matches
						.map(
							(match, index) =>
								`### Result ${index + 1} of ${matches.length}\nChannel: #${match.channel?.name ?? ""} (ID: ${match.channel?.id ?? ""})\nFrom: ${from(match)}\nTime: ${time(match.ts)}\nMessage_ts: ${match.ts}\nPermalink: ${match.permalink ?? ""}\nText:\n${match.text ?? ""}`,
						)
						.join("\n\n")}`
				: `# Search Results for: ${query}\n\nNo results found.`;
			return { value: { results, pagination_info: "End of results - No more pages available." } };
		}
		case "reactions":
			return { result: await call("SLACK_GET_REACTIONS", { channel: args.channel_id, ts: args.message_ts }) };
		case "startSlack":
		case "doneSlack": {
			const result = await call("SLACK_ADD_REACTION", {
				channel: args.channel_id,
				ts: args.message_ts,
				name: args.emoji,
			});
			unifiedJson(result);
			return { value: { ok: true } };
		}
		case "replySlack": {
			const value = unifiedJson(
				await call("SLACK_POST_MESSAGE", {
					channel: args.channel_id,
					thread_ts: args.thread_ts,
					text: args.message,
				}),
			);
			return { value: { ok: true, posted: value.posted === true } };
		}
		case "myChannels":
		case "searchChannels": {
			const value = unifiedJson(
				await call("SLACK_LIST_CHANNELS", { types: ["public_channels", "private_channels"] }),
			);
			const all =
				((value.channels ?? value.conversations) as
					| Array<{ id?: string; name?: string; is_private?: boolean; is_member?: boolean; type?: string }>
					| undefined) ?? [];
			const words = (Array.isArray(args.keywords) ? args.keywords : []).map((word) => String(word).toLowerCase());
			const isPrivate = (channel: (typeof all)[number]) =>
				channel.is_private === true || /private/.test(channel.type ?? "");
			const channels = all.filter(
				(channel) =>
					channel.id &&
					channel.name &&
					(logicalTool === "myChannels"
						? channel.is_member !== false
						: words.every((word) => channel.name!.toLowerCase().includes(word))),
			);
			if (logicalTool === "myChannels") {
				const shown = channels.slice(0, Number(args.limit ?? 200));
				return {
					value: {
						result: shown.length
							? `## My Channels\n\n${shown.map((channel) => `### #${channel.name}\n- **ID:** ${channel.id}\n- **Type:** ${isPrivate(channel) ? "Private" : "Public"} Channel`).join("\n\n")}${channels.length > shown.length ? "\n\nThere are more results available." : ""}`
							: "You are not a member of any channels.",
					},
				};
			}
			const shown = channels.slice(0, Number(args.limit ?? 20));
			return {
				value: {
					results: shown.length
						? `## Channels (${shown.length} results)\n${shown.map((channel, index) => `${index + 1}. #${channel.name} (${channel.id}) - ${isPrivate(channel) ? "private_channel" : "public_channel"}`).join("\n")}`
						: "No results found.",
					pagination_info: "",
				},
			};
		}
	}
	throw new SourceToolError(`Slack ${logicalTool} is not available through unified-mcp`);
}
