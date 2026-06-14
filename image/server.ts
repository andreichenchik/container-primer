import { createServer } from "node:http";
import {
	AuthStorage,
	createAgentSession,
	ModelRegistry,
	SessionManager,
} from "@earendil-works/pi-coding-agent";

const PORT = Number(process.argv[2] ?? 8080);
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

const PAGE = `<!doctype html>
<html>
	<head>
		<meta charset="utf-8" />
		<meta name="viewport" content="width=device-width, initial-scale=1" />
		<title>Primer Agent</title>
		<style>
			body { font-family: system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1rem; }
			form { display: flex; gap: 0.5rem; }
			input { flex: 1; padding: 0.5rem; font-size: 1rem; }
			button { padding: 0.5rem 1rem; font-size: 1rem; }
			#out { white-space: pre-wrap; margin-top: 1.5rem; padding: 1rem; background: #f4f4f4; border-radius: 6px; min-height: 2rem; }
		</style>
	</head>
	<body>
		<h1>Ask the workspace</h1>
		<form id="f">
			<input id="q" name="q" placeholder="Ask a question about /workspace…" autofocus />
			<button type="submit">Ask</button>
		</form>
		<div id="out"></div>
		<script>
			const f = document.getElementById("f");
			const q = document.getElementById("q");
			const out = document.getElementById("out");
			f.addEventListener("submit", async (e) => {
				e.preventDefault();
				const question = q.value.trim();
				if (!question) return;
				out.textContent = "Thinking…";
				try {
					const res = await fetch("/ask", { method: "POST", body: question });
					const text = await res.text();
					out.textContent = text;
				} catch (err) {
					out.textContent = "Request failed: " + err;
				}
			});
		</script>
	</body>
</html>
`;

const server = createServer((req, res) => {
	if (req.method === "GET" && req.url === "/") {
		res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
		res.end(PAGE);
		return;
	}
	if (req.method === "POST" && req.url === "/ask") {
		let body = "";
		req.on("data", (chunk) => {
			body += chunk;
		});
		req.on("end", async () => {
			try {
				const answer = await ask(body.trim());
				res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
				res.end(answer);
			} catch (err) {
				res.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
				res.end(`error: ${err instanceof Error ? err.message : String(err)}`);
			}
		});
		return;
	}
	res.writeHead(404).end();
});

server.listen(PORT, () => console.log(`Server running on port ${PORT}`));
