import assert from "node:assert/strict";
import test from "node:test";
import { ASK_TOOL_NAMES } from "./ask-tools.ts";
import { askPermitsTool } from "./native-adapter.ts";

test("Ask permits the user's MCP tools; diagnostics permits only its own list", () => {
	assert.equal(askPermitsTool(ASK_TOOL_NAMES, "mcp__unified_mcp__CALL_TOOL"), true);
	assert.equal(askPermitsTool(ASK_TOOL_NAMES, "read_mcp_resource"), true);
	assert.equal(askPermitsTool(ASK_TOOL_NAMES, "read"), true);
	assert.equal(askPermitsTool(ASK_TOOL_NAMES, "bash"), false);
	assert.equal(askPermitsTool(ASK_TOOL_NAMES, "write"), false);
	assert.equal(askPermitsTool(["diagnostics"], "mcp__slack__post"), false);
});
