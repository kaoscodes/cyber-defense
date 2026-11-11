#!/usr/bin/env bun
// Live CLI chat against the RunPod endpoint through the Vercel AI SDK, to check
// streaming, reasoning, tool calling and real per-request speed.
//
//   bun run chat                          interactive chat (keeps history)
//   bun run chat "explain SSRF"           one-shot
//   bun run chat --effort xhigh --tools   options, see --help
import { createOpenAICompatible } from "@ai-sdk/openai-compatible";
import { type ModelMessage, stepCountIs, streamText, tool } from "ai";
import { parseArgs } from "node:util";
import { createInterface } from "node:readline/promises";
import { z } from "zod";

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    effort: { type: "string", default: "low" },
    "max-tokens": { type: "string", default: "8192" },
    temperature: { type: "string" },
    system: { type: "string" },
    tools: { type: "boolean", default: false },
    "hide-reasoning": { type: "boolean", default: false },
    "base-url": { type: "string" },
    "env-file": { type: "string", default: ".env" },
    help: { type: "boolean", short: "h", default: false },
  },
});

if (opts.help) {
  console.log(`usage: bun run chat [options] [prompt]

  --effort low|medium|xhigh   reasoning effort (default low; model default is xhigh)
  --max-tokens N              output token limit incl. reasoning (default 8192)
  --temperature T             sampling temperature (default: model's 1.0)
  --system TEXT               system prompt
  --tools                     enable a demo tool to test tool calling
  --hide-reasoning            don't print reasoning (still timed)
  --base-url URL              endpoint to test (default: OPENAI_BASE_URL from the env file)
  --env-file NAME             env file in the repo root (default .env, e.g. .env.bench)

In chat: /reset clears history, /exit quits, Ctrl+C stops a running answer.`);
  process.exit(0);
}

const EFFORTS = ["low", "medium", "xhigh"] as const;
type Effort = (typeof EFFORTS)[number];
if (!EFFORTS.includes(opts.effort as Effort)) {
  console.error(`--effort must be one of ${EFFORTS.join(", ")} (the model's chat template rejects others)`);
  process.exit(1);
}

// The repo's .env wins over the shell: a stale `export OPENAI_BASE_URL` left
// over from sourcing an old .env otherwise silently targets a retired endpoint.
const dotenv = await Bun.file(new URL(`../${opts["env-file"]}`, import.meta.url)).text().catch(() => "");
const fileEnv = Object.fromEntries(
  dotenv.split("\n").flatMap((l) => {
    const m = l.match(/^\s*([A-Z0-9_]+)=(.*)$/);
    return m ? [[m[1], m[2].trim().replace(/^(["'])(.*)\1$/, "$2")]] : [];
  }),
);
const OPENAI_BASE_URL = opts["base-url"] ?? fileEnv.OPENAI_BASE_URL ?? process.env.OPENAI_BASE_URL;
const RUNPOD_API_KEY = fileEnv.RUNPOD_API_KEY ?? process.env.RUNPOD_API_KEY;
if (!OPENAI_BASE_URL || !RUNPOD_API_KEY) {
  console.error("OPENAI_BASE_URL and RUNPOD_API_KEY must be set in ../.env");
  process.exit(1);
}

const c = {
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  cyan: (s: string) => `\x1b[36m${s}\x1b[0m`,
  yellow: (s: string) => `\x1b[33m${s}\x1b[0m`,
  red: (s: string) => `\x1b[31m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`,
};

// llama-server appends a non-standard `timings` object to the final stream
// chunk (server-side speed, speculative-decoding acceptance). Surface it as
// provider metadata so it can be shown next to the client-side numbers.
type Timings = {
  prompt_n: number;
  prompt_ms: number;
  predicted_n: number;
  predicted_per_second: number;
  draft_n?: number;
  draft_n_accepted?: number;
};

const provider = createOpenAICompatible({
  name: "runpod",
  baseURL: OPENAI_BASE_URL,
  apiKey: RUNPOD_API_KEY,
  includeUsage: true,
  metadataExtractor: {
    extractMetadata: async ({ parsedBody }) => {
      const timings = (parsedBody as { timings?: Timings }).timings;
      return timings ? { llamacpp: timings } : undefined;
    },
    createStreamExtractor: () => {
      let timings: Timings | undefined;
      return {
        processChunk: (chunk) => {
          timings = (chunk as { timings?: Timings }).timings ?? timings;
        },
        buildMetadata: () => (timings ? { llamacpp: timings } : undefined),
      };
    },
  },
});
const model = provider.chatModel("cyberorca");

const tools = {
  lookup_cve: tool({
    description: "Look up details for a CVE identifier.",
    inputSchema: z.object({ id: z.string().describe("CVE id, e.g. CVE-2021-44228") }),
    execute: async ({ id }) =>
      id.toUpperCase() === "CVE-2021-44228"
        ? { id, name: "Log4Shell", cvss: 10.0, affected: "Apache Log4j 2.0-beta9 to 2.14.1", fix: "upgrade to 2.17.1+" }
        : { id, error: "not in demo database (only CVE-2021-44228 is)" },
  }),
};

const history: ModelMessage[] = [];
let abort: AbortController | undefined;

process.on("SIGINT", () => {
  if (abort) abort.abort();
  else process.exit(0);
});

async function turn(prompt: string) {
  history.push({ role: "user", content: prompt });
  abort = new AbortController();

  const start = performance.now();
  let firstToken: number | undefined;
  let firstText: number | undefined;
  let lastToken = start;
  let inReasoning = false;
  const mark = () => {
    lastToken = performance.now();
    firstToken ??= lastToken;
  };

  const result = streamText({
    model,
    system: opts.system,
    messages: history,
    reasoning: opts.effort as Effort,
    maxOutputTokens: Number(opts["max-tokens"]),
    temperature: opts.temperature === undefined ? undefined : Number(opts.temperature),
    tools: opts.tools ? tools : undefined,
    stopWhen: stepCountIs(opts.tools ? 5 : 1),
    abortSignal: abort.signal,
    onError: () => {}, // errors are surfaced via the stream's "error" part below
  });

  const steps: { tokens?: number; timings?: Timings }[] = [];
  try {
    for await (const part of result.fullStream) {
      switch (part.type) {
        case "reasoning-delta":
          mark();
          if (!opts["hide-reasoning"]) {
            if (!inReasoning) process.stdout.write(c.dim("thinking: "));
            process.stdout.write(c.dim(part.text));
          }
          inReasoning = true;
          break;
        case "text-delta":
          mark();
          firstText ??= lastToken;
          if (inReasoning) {
            if (!opts["hide-reasoning"]) process.stdout.write("\n\n");
            inReasoning = false;
          }
          process.stdout.write(part.text);
          break;
        case "tool-call":
          process.stdout.write(c.cyan(`\n→ ${part.toolName}(${JSON.stringify(part.input)})\n`));
          break;
        case "tool-result":
          process.stdout.write(c.cyan(`← ${JSON.stringify(part.output)}\n`));
          break;
        case "tool-error":
          process.stdout.write(c.red(`← tool error: ${String(part.error)}\n`));
          break;
        case "finish-step":
          steps.push({
            tokens: part.usage.outputTokens,
            timings: part.providerMetadata?.llamacpp as Timings | undefined,
          });
          break;
        case "error":
          throw part.error;
      }
    }
    history.push(...(await result.response).messages);
  } catch (err) {
    history.pop(); // drop the unanswered user message so the chat can continue
    let msg = abort.signal.aborted ? "stopped" : err instanceof Error ? err.message : String(err);
    if (msg.includes("without a finish reason"))
      msg += " — the endpoint returned an empty stream; check that it has workers (max > 0) and the URL is current";
    process.stdout.write(c.red(`\n[${msg}]\n`));
    abort = undefined;
    return;
  }
  abort = undefined;
  process.stdout.write("\n");
  printStats(start, firstToken, firstText, lastToken, steps);
}

function printStats(
  start: number,
  firstToken: number | undefined,
  firstText: number | undefined,
  lastToken: number,
  steps: { tokens?: number; timings?: Timings }[],
) {
  const s = (ms: number) => `${(ms / 1000).toFixed(2)}s`;
  const tokens = steps.reduce((n, st) => n + (st.tokens ?? 0), 0);
  const parts = [
    `first token ${firstToken ? s(firstToken - start) : "-"}`,
    `first answer token ${firstText ? s(firstText - start) : "-"}`,
    `${tokens} tokens in ${s(lastToken - (firstToken ?? start))}`,
  ];
  // Client-side rate includes network and RunPod streaming overhead.
  if (firstToken && lastToken > firstToken) parts.push(`${(tokens / ((lastToken - firstToken) / 1000)).toFixed(0)} tok/s client`);

  const t = steps.map((st) => st.timings).filter((x): x is Timings => !!x);
  if (t.length) {
    const predicted = t.reduce((n, x) => n + x.predicted_n, 0);
    const genSec = t.reduce((n, x) => n + x.predicted_n / x.predicted_per_second, 0);
    parts.push(`${(predicted / genSec).toFixed(0)} tok/s server`);
    const drafted = t.reduce((n, x) => n + (x.draft_n ?? 0), 0);
    const accepted = t.reduce((n, x) => n + (x.draft_n_accepted ?? 0), 0);
    if (drafted) parts.push(`draft acceptance ${((accepted / drafted) * 100).toFixed(0)}%`);
    const promptN = t.reduce((n, x) => n + x.prompt_n, 0);
    const promptMs = t.reduce((n, x) => n + x.prompt_ms, 0);
    parts.push(`prompt ${promptN} tok in ${s(promptMs)}`);
  }
  if (steps.length > 1) parts.push(`${steps.length} steps`);
  console.log(c.yellow(`[${parts.join(" · ")}]`));
}

if (positionals.length) {
  await turn(positionals.join(" "));
} else {
  console.log(c.bold(`Chat · ${OPENAI_BASE_URL}`));
  console.log(c.dim(`effort=${opts.effort}${opts.tools ? " · tools on" : ""} · /reset, /exit, Ctrl+C stops an answer\n`));
  for await (const raw of inputLines()) {
    const line = raw.trim();
    if (line === "/exit") break;
    if (line === "/reset") {
      history.length = 0;
      console.log(c.dim("history cleared"));
    } else if (line) {
      await turn(line);
      console.log();
    }
  }
  process.exit(0);
}

// Interactive prompt on a terminal; piped stdin (e.g. scripted tests) is read
// up front, since readline closes at EOF while an answer is still streaming.
async function* inputLines() {
  if (!process.stdin.isTTY) {
    for (const line of (await Bun.stdin.text()).split("\n")) {
      console.log(c.bold(`› ${line}`));
      yield line;
    }
    return;
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.on("SIGINT", () => (abort ? abort.abort() : process.exit(0)));
  while (true) yield await rl.question(c.bold("› "));
}
