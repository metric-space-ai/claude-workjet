import { rmSync } from "node:fs";
import net from "node:net";
import { pathToFileURL } from "node:url";
import { posix as path } from "node:path";
import { runAgentLoop, type AgentContext, type AgentEvent, type AgentMessage, type AgentTool, type StreamFn } from "@earendil-works/pi-agent-core";
import { stream as streamOpenAIResponses } from "@earendil-works/pi-ai/api/openai-responses";
import type { Api, Message, Model } from "@earendil-works/pi-ai";
import { Type, type Static } from "typebox";

const MAX_REQUEST_BYTES = 8 * 1024 * 1024;
const MAX_ASSISTANT_TURNS = 24;

type FileMap = Record<string, string>;

export type TurnRequest = {
  id?: string;
  method?: "turn";
  prompt: string;
  files?: FileMap;
  systemPrompt?: string;
  maxAssistantTurns?: number;
  model: {
    id: string;
    name?: string;
    provider: "ctox-gateway";
    api: "openai-responses";
    baseUrl: string;
    contextWindow?: number;
    maxTokens?: number;
    reasoning?: boolean;
  };
};

export type HealthRequest = { id?: string; method: "health" };

export type SidecarResponse = {
  id?: string;
  ok: boolean;
  error?: string;
  health?: "ok";
  messages?: AgentMessage[];
  events?: AgentEvent[];
  snapshot?: Array<{ path: string; content: string }>;
};

class MemoryWorkspace {
  readonly files = new Map<string, string>();

  constructor(seed: FileMap = {}) {
    for (const [filePath, content] of Object.entries(seed)) {
      this.files.set(normalizePath(filePath), String(content));
    }
  }

  snapshot(): Array<{ path: string; content: string }> {
    return [...this.files.entries()]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([filePath, content]) => ({ path: filePath, content }));
  }
}

const readSchema = Type.Object({ path: Type.String() });
const writeSchema = Type.Object({ path: Type.String(), content: Type.String() });
const listSchema = Type.Object({ prefix: Type.Optional(Type.String()) });
const grepSchema = Type.Object({ pattern: Type.String(), prefix: Type.Optional(Type.String()) });

function toolsFor(workspace: MemoryWorkspace): AgentTool[] {
  return [
    {
      name: "read",
      label: "read",
      description: "Read a UTF-8 file from the isolated in-memory workspace.",
      parameters: readSchema,
      async execute(_id, input) {
        const args = input as Static<typeof readSchema>;
        const filePath = normalizePath(args.path);
        const content = workspace.files.get(filePath);
        if (content === undefined) return textResult(`File not found: ${filePath}`, true);
        return textResult(content);
      },
    },
    {
      name: "write",
      label: "write",
      description: "Create or replace a UTF-8 file in the isolated in-memory workspace.",
      parameters: writeSchema,
      async execute(_id, input) {
        const args = input as Static<typeof writeSchema>;
        const filePath = normalizePath(args.path);
        workspace.files.set(filePath, args.content);
        return textResult(`Wrote ${filePath}`);
      },
    },
    {
      name: "list",
      label: "list",
      description: "List files in the isolated in-memory workspace.",
      parameters: listSchema,
      async execute(_id, input) {
        const args = input as Static<typeof listSchema>;
        const prefix = args.prefix ? normalizePath(args.prefix) : "";
        const files = [...workspace.files.keys()].filter((filePath) => filePath.startsWith(prefix)).sort();
        return textResult(files.join("\n") || "(empty)");
      },
    },
    {
      name: "grep",
      label: "grep",
      description: "Search workspace text with a JavaScript regular expression.",
      parameters: grepSchema,
      async execute(_id, input) {
        const args = input as Static<typeof grepSchema>;
        let expression: RegExp;
        try {
          expression = new RegExp(args.pattern, "u");
        } catch (error) {
          return textResult(`Invalid pattern: ${errorMessage(error)}`, true);
        }
        const prefix = args.prefix ? normalizePath(args.prefix) : "";
        const matches: string[] = [];
        for (const [filePath, content] of workspace.files) {
          if (!filePath.startsWith(prefix)) continue;
          content.split("\n").forEach((line, index) => {
            expression.lastIndex = 0;
            if (expression.test(line) && matches.length < 200) matches.push(`${filePath}:${index + 1}:${line}`);
          });
        }
        return textResult(matches.join("\n") || "(no matches)");
      },
    },
  ];
}

function textResult(text: string, isError = false) {
  return { content: [{ type: "text" as const, text }], details: undefined, isError };
}

function normalizePath(value: string): string {
  if (value.includes("\0")) throw new Error("NUL is not allowed in workspace paths");
  const normalized = path.normalize(`/${value}`).slice(1);
  if (!normalized || normalized === "." || normalized.startsWith("../")) throw new Error("invalid workspace path");
  return normalized;
}

function gatewayModel(input: TurnRequest["model"]): Model<"openai-responses"> {
  if (input.provider !== "ctox-gateway" || input.api !== "openai-responses") {
    throw new Error("only the ctox-gateway OpenAI Responses adapter is allowed");
  }
  const gateway = new URL(input.baseUrl);
  if (gateway.protocol !== "http:" || gateway.username || gateway.password || !isLoopback(gateway.hostname)) {
    throw new Error("model gateway must be credential-free HTTP loopback");
  }
  return {
    id: input.id,
    name: input.name ?? input.id,
    provider: "ctox-gateway",
    api: "openai-responses",
    baseUrl: gateway.href,
    reasoning: input.reasoning ?? false,
    input: ["text", "image"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: input.contextWindow ?? 128_000,
    maxTokens: input.maxTokens ?? 16_384,
  };
}

function isLoopback(hostname: string): boolean {
  return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "[::1]";
}

export async function handleRequest(request: TurnRequest | HealthRequest, streamFn?: StreamFn): Promise<SidecarResponse> {
  if (request.method === "health") return { id: request.id, ok: true, health: "ok" };
  try {
    if (!request.prompt || typeof request.prompt !== "string") throw new Error("prompt is required");
    const workspace = new MemoryWorkspace(request.files);
    const model = gatewayModel(request.model);
    const events: AgentEvent[] = [];
    const context: AgentContext = {
      systemPrompt: request.systemPrompt ?? defaultSystemPrompt(),
      messages: [],
      tools: toolsFor(workspace),
    };
    const prompt: Message = { role: "user", content: request.prompt, timestamp: Date.now() };
    const turnLimit = Math.max(1, Math.min(MAX_ASSISTANT_TURNS, request.maxAssistantTurns ?? 12));
    let turns = 0;
    const messages = await runAgentLoop(
      [prompt],
      context,
      {
        model,
        apiKey: "ctox-loopback-public-sentinel",
        convertToLlm: (items) => items.filter(isMessage),
        toolExecution: "sequential",
        maxRetries: 0,
        shouldStopAfterTurn: ({ message }) => {
          if (message.role === "assistant") turns += 1;
          return turns >= turnLimit || (message.role === "assistant" && !message.content.some((part) => part.type === "toolCall"));
        },
      },
      (event) => {
        events.push(event);
      },
      undefined,
      streamFn ?? ((selectedModel, selectedContext, options) => streamOpenAIResponses(selectedModel as Model<"openai-responses">, selectedContext, options)),
    );
    return { id: request.id, ok: true, messages, events, snapshot: workspace.snapshot() };
  } catch (error) {
    return { id: request.id, ok: false, error: errorMessage(error) };
  }
}

function isMessage(value: AgentMessage): value is Message {
  return value.role === "user" || value.role === "assistant" || value.role === "toolResult";
}

function defaultSystemPrompt(): string {
  return [
    "You are a bounded Pi coding agent operating on an isolated in-memory file snapshot.",
    "Use only read, write, list, and grep. There is no host filesystem, shell, package manager, plugin loader, or general network tool.",
    "Return after completing the requested source edit. The owner reviews and persists the returned snapshot.",
  ].join("\n");
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function startOneShotServer(socketPath: string): net.Server {
  rmSync(socketPath, { force: true });
  let accepted = false;
  const server = net.createServer((socket) => {
    if (accepted) {
      socket.end(`${JSON.stringify({ ok: false, error: "sidecar already served its one request" })}\n`);
      return;
    }
    accepted = true;
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      if (Buffer.byteLength(buffer) > MAX_REQUEST_BYTES) socket.destroy(new Error("request exceeds 8 MiB"));
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const line = buffer.slice(0, newline);
      socket.pause();
      void dispatchLine(line, socket, server, socketPath);
    });
  });
  server.listen(socketPath);
  return server;
}

async function dispatchLine(line: string, socket: net.Socket, server: net.Server, socketPath: string): Promise<void> {
  let response: SidecarResponse;
  try {
    response = await handleRequest(JSON.parse(line) as TurnRequest | HealthRequest);
  } catch (error) {
    response = { ok: false, error: errorMessage(error) };
  }
  socket.end(`${JSON.stringify(response)}\n`, () => {
    server.close(() => rmSync(socketPath, { force: true }));
  });
}

function installCleanup(server: net.Server, socketPath: string): void {
  const cleanup = () => {
    server.close();
    rmSync(socketPath, { force: true });
  };
  process.once("SIGINT", cleanup);
  process.once("SIGTERM", cleanup);
  process.once("exit", () => rmSync(socketPath, { force: true }));
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (entry === import.meta.url) {
  const socketPath = process.argv[2];
  if (!socketPath) {
    console.error("usage: ctox-pi-sidecar.mjs <unix-socket-path>");
    process.exit(2);
  }
  const server = startOneShotServer(socketPath);
  installCleanup(server, socketPath);
}
