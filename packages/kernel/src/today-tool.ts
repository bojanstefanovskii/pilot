/** The `today_write` tool: a Today Desk routine writes the user's Today page in Pilot. Executed by pilotd. */
import type { JsonValue } from "@earendil-works/chord";
import { Type } from "@earendil-works/pi-ai";
import { type AgentToolResult, defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";

export const TODAY_TOOL = "today_write";
export type TodayCall = (args: Record<string, JsonValue>) => Promise<JsonValue>;

const item = Type.Object({
	id: Type.Optional(Type.String({ maxLength: 80, description: "Stable id; reuse it when rewriting the same item." })),
	title: Type.String({ maxLength: 200 }),
	why: Type.Optional(Type.String({ maxLength: 400, description: "Why it matters today, one sentence." })),
	url: Type.Optional(Type.String({ maxLength: 2000, description: "https link to the ticket, PR or message." })),
	source: Type.Optional(Type.String({ maxLength: 80, description: 'e.g. "Linear", "Slack · Sarah", "GitHub #123".' })),
	effort: Type.Optional(Type.String({ maxLength: 20 })),
	prompt: Type.Optional(Type.String({ maxLength: 4000, description: "What to ask an agent if the user starts it." })),
});

export function createTodayTool(call: TodayCall): ToolDefinition {
	return defineTool({
		name: TODAY_TOOL,
		label: "Today page",
		description:
			"Write the user's Today page in Pilot. Each section you pass replaces that section for the day; sections you omit stay. The user's done marks survive by item id. Read the current page first with read: true.",
		promptSnippet: "Read or write the user's Today page",
		parameters: Type.Object({
			read: Type.Optional(Type.Boolean({ description: "Return the current page without writing." })),
			date: Type.Optional(Type.String({ description: "YYYY-MM-DD, local. Defaults to today." })),
			summary: Type.Optional(Type.String({ maxLength: 1000 })),
			priorities: Type.Optional(Type.Array(item, { maxItems: 30 })),
			reviews: Type.Optional(Type.Array(item, { maxItems: 30 })),
			quickWins: Type.Optional(Type.Array(item, { maxItems: 30 })),
			waiting: Type.Optional(Type.Array(item, { maxItems: 30 })),
			lessons: Type.Optional(Type.Array(Type.String({ maxLength: 300 }), { maxItems: 40 })),
			wrap: Type.Optional(Type.String({ maxLength: 4000, description: "End-of-day recap." })),
		}),
		executionMode: "sequential",
		async execute(_callId, params): Promise<AgentToolResult<JsonValue>> {
			const result = await call(params as unknown as Record<string, JsonValue>);
			return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
		},
	});
}
