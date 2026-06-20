import { Hono } from "hono";
import {
	AuthStorage,
	createAgentSession,
	ModelRegistry,
	SessionManager,
} from "@earendil-works/pi-coding-agent";
import PAGE from "./index.html" with { type: "text" };

const PORT = Number(process.env.PORT ?? 8080);
const WORKSPACE = "/workspace";
const PROVIDER = "openai";

const baseUrl = process.env.OPENAI_BASE_URL;
const apiKey = process.env.OPENAI_API_KEY;
const modelId = process.env.OPENAI_MODEL;

if (!baseUrl || !apiKey || !modelId) {
	console.error("OPENAI_BASE_URL, OPENAI_API_KEY and OPENAI_MODEL must be set");
	process.exit(1);
}

// Register an OpenAI-compatible provider/model from env. Auth and models live in
// memory only — nothing is read from or written to ~/.pi.
const authStorage = AuthStorage.inMemory();
const modelRegistry = ModelRegistry.inMemory(authStorage);
modelRegistry.registerProvider(PROVIDER, {
	baseUrl,
	apiKey,
	api: "openai-completions",
	models: [
		{
			id: modelId,
			name: modelId,
			reasoning: false,
			input: ["text"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: 128000,
			maxTokens: 16384,
		},
	],
});

const model = modelRegistry.find(PROVIDER, modelId);
if (!model) {
	console.error(`model ${modelId} not found after registration`);
	process.exit(1);
}

console.log(`[primer] endpoint=${baseUrl} model=${modelId} apiKeyLen=${apiKey.length}`);

// Answer a question in a fresh agent session that can read the workspace.
// Logs agent events to stderr and surfaces the underlying error if the model
// produces no text (e.g. the endpoint is unreachable from inside the container).
async function ask(question: string): Promise<string> {
	const { session } = await createAgentSession({
		model,
		cwd: WORKSPACE,
		agentDir: "/tmp/pi-agent",
		tools: ["read", "grep", "find", "ls"],
		sessionManager: SessionManager.inMemory(WORKSPACE),
		authStorage,
		modelRegistry,
	});

	let lastError: string | undefined;
	const unsubscribe = session.subscribe((event) => {
		switch (event.type) {
			case "message_update": {
				const e = event.assistantMessageEvent;
				if (e.type === "error") {
					lastError = e.error?.errorMessage ?? `stream error (${e.reason})`;
					console.error(`[pi] stream error: ${lastError}`);
				}
				break;
			}
			case "tool_execution_end":
				console.error(`[pi] tool ${event.toolName} ${event.isError ? "ERROR" : "ok"}`);
				break;
			case "auto_retry_start":
				lastError = event.errorMessage;
				console.error(`[pi] retry ${event.attempt}/${event.maxAttempts}: ${event.errorMessage}`);
				break;
			case "agent_end":
				console.error(`[pi] agent_end (messages=${event.messages.length})`);
				break;
			default:
				console.error(`[pi] ${event.type}`);
		}
	});

	try {
		await session.prompt(question);
		const text = session.getLastAssistantText();
		if (text && text.trim()) return text;
		throw new Error(lastError ?? "agent produced no response");
	} finally {
		unsubscribe();
		session.dispose();
	}
}

const app = new Hono();

app.get("/", (c) => c.html(PAGE));

app.post("/ask", async (c) => {
	try {
		return c.text(await ask((await c.req.text()).trim()));
	} catch (err) {
		return c.text(`error: ${err instanceof Error ? err.message : String(err)}`, 500);
	}
});

console.log(`Server running on port ${PORT}`);

export default { port: PORT, fetch: app.fetch };
