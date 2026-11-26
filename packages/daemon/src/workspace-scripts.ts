import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { promisify } from "node:util";
import type { WorkspaceScriptResult, WorkspaceScriptStep, WorkspaceScripts } from "@pilot/protocol";

/** Default and maximum time one step may run. Setup blocks the first turn, so it stays bounded. */
export const SCRIPT_TIMEOUT_MS = 10 * 60_000;
export const SCRIPT_MAX_TIMEOUT_MS = 30 * 60_000;
/** Only the tail of a step's output is kept: enough to show why it failed, never a whole build log. */
export const SCRIPT_OUTPUT_CAP = 16 * 1024;
const MAX_STEPS = 20;
const MAX_COMMAND = 4000;

/** Validate a project's scripts before saving. Empty lists and an empty run command are dropped. */
export function validateWorkspaceScripts(value: unknown): WorkspaceScripts | undefined {
	if (value === null) return undefined;
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("scripts must be an object");
	const input = value as Record<string, unknown>;
	for (const key of Object.keys(input))
		if (!["setup", "quickSetup", "agentSetup", "run", "checks", "teardown"].includes(key))
			throw new Error(`Unknown scripts field: ${key}`);
	const steps = (
		field: "setup" | "quickSetup" | "agentSetup" | "checks" | "teardown",
	): WorkspaceScriptStep[] | undefined => {
		const list = input[field];
		if (list === undefined) return undefined;
		if (!Array.isArray(list) || list.length > MAX_STEPS)
			throw new Error(`scripts.${field} must be a list of at most ${MAX_STEPS} steps`);
		const result = list.map((step, index) => validateStep(step, `scripts.${field}[${index}]`));
		return result.length ? result : undefined;
	};
	const setup = steps("setup");
	const checks = steps("checks");
	const teardown = steps("teardown");
	const quickSetup = steps("quickSetup");
	const agentSetup = steps("agentSetup");
	let run: string | undefined;
	if (input.run !== undefined) {
		if (typeof input.run !== "string" || input.run.length > MAX_COMMAND)
			throw new Error(`scripts.run must be a command of at most ${MAX_COMMAND} characters`);
		run = input.run.trim() || undefined;
	}
	if (!setup && !quickSetup && !agentSetup && !checks && !teardown && !run) return undefined;
	return {
		...(setup ? { setup } : {}),
		...(quickSetup ? { quickSetup } : {}),
		...(agentSetup ? { agentSetup } : {}),
		...(run ? { run } : {}),
		...(checks ? { checks } : {}),
		...(teardown ? { teardown } : {}),
	};
}

function validateStep(value: unknown, at: string): WorkspaceScriptStep {
	if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${at} must be an object`);
	const step = value as Record<string, unknown>;
	if (typeof step.command !== "string" || !step.command.trim() || step.command.length > MAX_COMMAND)
		throw new Error(`${at}.command must be 1 to ${MAX_COMMAND} characters`);
	if (step.name !== undefined && (typeof step.name !== "string" || step.name.length > 80))
		throw new Error(`${at}.name must be at most 80 characters`);
	if (
		step.timeoutMs !== undefined &&
		(typeof step.timeoutMs !== "number" ||
			!Number.isInteger(step.timeoutMs) ||
			step.timeoutMs < 1000 ||
			step.timeoutMs > SCRIPT_MAX_TIMEOUT_MS)
	)
		throw new Error(`${at}.timeoutMs must be between 1000 and ${SCRIPT_MAX_TIMEOUT_MS}`);
	return {
		command: step.command.trim(),
		...(typeof step.name === "string" && step.name.trim() ? { name: step.name.trim() } : {}),
		...(typeof step.timeoutMs === "number" ? { timeoutMs: step.timeoutMs } : {}),
	};
}

export interface RunScriptsOptions {
	cwd: string;
	/** Added to the daemon's environment: PILOT_SESSION_ID, PILOT_WORKSPACE, PILOT_PROJECT_PATH, ... */
	env: Record<string, string>;
	signal?: AbortSignal;
	shell?: string;
	now?: () => number;
}

/** Run steps in order and stop at the first failure. Never throws for a failing step; the caller reads `ok`. */
export async function runWorkspaceScripts(
	steps: WorkspaceScriptStep[],
	options: RunScriptsOptions,
): Promise<{ ok: boolean; results: WorkspaceScriptResult[] }> {
	const results: WorkspaceScriptResult[] = [];
	for (const step of steps) {
		options.signal?.throwIfAborted();
		const result = await runStep(step, options);
		results.push(result);
		if (result.exitCode !== 0) return { ok: false, results };
	}
	return { ok: true, results };
}

function runStep(step: WorkspaceScriptStep, options: RunScriptsOptions): Promise<WorkspaceScriptResult> {
	const now = options.now ?? Date.now;
	const started = now();
	const timeoutMs = step.timeoutMs ?? SCRIPT_TIMEOUT_MS;
	return new Promise((resolve, reject) => {
		// A login shell gives the step the user's PATH (mise, pnpm, nvm), as in their own terminal.
		const child = spawn(options.shell ?? "/bin/zsh", ["-lc", step.command], {
			cwd: options.cwd,
			env: { ...process.env, ...options.env },
			stdio: ["ignore", "pipe", "pipe"],
			detached: true,
		});
		let output = "";
		const append = (chunk: Buffer) => {
			output += chunk.toString("utf8");
			if (output.length > SCRIPT_OUTPUT_CAP * 2) output = output.slice(-SCRIPT_OUTPUT_CAP);
		};
		child.stdout.on("data", append);
		child.stderr.on("data", append);
		let timedOut = false;
		// Kill the whole process group: pnpm and turbo children must not outlive a stopped setup.
		const kill = () => {
			try {
				if (child.pid) process.kill(-child.pid, "SIGTERM");
			} catch {}
		};
		const timer = setTimeout(() => {
			timedOut = true;
			kill();
		}, timeoutMs);
		const onAbort = () => kill();
		options.signal?.addEventListener("abort", onAbort, { once: true });
		const finish = () => {
			clearTimeout(timer);
			options.signal?.removeEventListener("abort", onAbort);
		};
		child.on("error", (error) => {
			finish();
			reject(error);
		});
		child.on("close", (code, signal) => {
			finish();
			if (options.signal?.aborted) return reject(options.signal.reason);
			resolve({
				...(step.name ? { name: step.name } : {}),
				command: step.command,
				exitCode: timedOut ? 124 : (code ?? (signal ? 128 : 1)),
				durationMs: now() - started,
				output: output.slice(-SCRIPT_OUTPUT_CAP),
				...(timedOut ? { timedOut: true } : {}),
			});
		});
	});
}

/** One line for a chat event or a failure reason, such as `Setup failed: install deps (exit 1)`. */
export function describeScriptFailure(kind: "Setup" | "Checks" | "Teardown", result: WorkspaceScriptResult): string {
	const label = result.name ?? result.command.slice(0, 80);
	return `${kind} failed: ${label} (${result.timedOut ? "timed out" : `exit ${result.exitCode}`})`;
}

const execFileAsync = promisify(execFile);

/** Identifies the workspace's content: HEAD plus every changed or untracked path. Undefined outside Git. */
export async function workspaceFingerprint(cwd: string): Promise<string | undefined> {
	try {
		const git = (...args: string[]) =>
			execFileAsync("git", ["-C", cwd, ...args], { maxBuffer: 16 * 1024 * 1024, timeout: 30_000 });
		const [head, status] = await Promise.all([
			git("rev-parse", "HEAD").then(
				({ stdout }) => stdout.trim(),
				() => "",
			),
			git("status", "--porcelain=v1", "--untracked-files=all", "-z"),
		]);
		return createHash("sha256").update(head).update("\0").update(status.stdout).digest("hex");
	} catch {
		return undefined;
	}
}
