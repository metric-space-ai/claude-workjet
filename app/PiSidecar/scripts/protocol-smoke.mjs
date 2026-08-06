import { mkdtemp, readFile, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const root = path.resolve(new URL("../..", import.meta.url).pathname);
const bundle = path.join(root, "ReleaseInputs/ctox-pi-sidecar.mjs");
const { handleRequest } = await import(bundle);
const now = Date.now();
const assistant = {
  role: "assistant",
  content: [{ type: "text", text: "offline smoke" }],
  api: "openai-responses",
  provider: "ctox-gateway",
  model: "smoke-model",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  stopReason: "stop",
  timestamp: now,
};
const fakeStream = () => ({
  async *[Symbol.asyncIterator]() { yield { type: "done", reason: "stop", message: assistant }; },
  async result() { return assistant; },
});
const turn = await handleRequest({
  id: "turn-smoke",
  prompt: "respond without tools",
  files: { "hello.txt": "hello" },
  model: { id: "smoke-model", provider: "ctox-gateway", api: "openai-responses", baseUrl: "http://127.0.0.1:12434/v1" },
}, fakeStream);
if (!turn.ok || turn.messages?.at(-1)?.role !== "assistant" || turn.snapshot?.[0]?.path !== "hello.txt") {
  throw new Error(`agent loop smoke failed: ${JSON.stringify(turn)}`);
}
const remote = await handleRequest({
  prompt: "must not leave loopback",
  model: { id: "blocked", provider: "ctox-gateway", api: "openai-responses", baseUrl: "https://api.openai.com/v1" },
}, fakeStream);
if (remote.ok || !remote.error?.includes("loopback")) throw new Error(`remote gateway was not rejected: ${JSON.stringify(remote)}`);
const temp = await mkdtemp(path.join(os.tmpdir(), "workjet-pi-smoke-"));
const socketPath = path.join(temp, "sidecar.sock");
const child = spawn(process.execPath, [bundle, socketPath], { stdio: ["ignore", "pipe", "pipe"] });
try {
  const response = await request(socketPath, { id: "smoke", method: "health" });
  if (!response.ok || response.health !== "ok" || response.id !== "smoke") throw new Error(`unexpected response: ${JSON.stringify(response)}`);
  await new Promise((resolve, reject) => {
    child.once("exit", (code) => code === 0 ? resolve() : reject(new Error(`sidecar exited ${code}`)));
    setTimeout(() => reject(new Error("sidecar did not exit after one request")), 5000).unref();
  });
  console.log("agent_loop_smoke=ok remote_gateway_rejection=ok protocol_smoke=ok one_shot_cleanup=ok");
} finally {
  child.kill("SIGKILL");
  await rm(temp, { recursive: true, force: true });
}

async function request(socketPath, body) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try {
      return await new Promise((resolve, reject) => {
        const socket = net.createConnection(socketPath);
        let text = "";
        socket.once("error", reject);
        socket.on("data", (chunk) => text += chunk);
        socket.once("connect", () => socket.write(`${JSON.stringify(body)}\n`));
        socket.once("end", () => {
          try { resolve(JSON.parse(text)); } catch (error) { reject(error); }
        });
      });
    } catch (error) {
      if (error?.code !== "ENOENT" && error?.code !== "ECONNREFUSED") throw error;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
  throw new Error(`socket unavailable: ${socketPath}`);
}
