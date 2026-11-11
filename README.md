<img src="assets/icon.svg" width="64" height="64" alt="">

# cyber-defense

This repository runs a security LLM on RunPod Serverless. You get an OpenAI-compatible endpoint that accepts text and images. When there are no requests, the endpoint stops all workers. You pay only when it runs.

- **Model:** CyberOrca, OrcaSAQ-2-Cyber-27B ([weights](https://huggingface.co/orcarouter/OrcaSAQ-2-Cyber-27B-Uncensored-GGUF), gated), with the vision projector of Qwen3.8-27B. 262,144 tokens of context. See [How it works](#how-it-works).
- **Server:** llama.cpp (`llama-server`), stock Docker image.
- **Speed:** approximately 150 to 225 tok/s for each request on an RTX 5090. See [Benchmarks](#benchmarks).
- **APIs:** OpenAI Chat Completions (`/v1/chat/completions`) and Anthropic Messages (`/v1/messages`). Streaming, reasoning, tool calls and image input work.

## Requirements

- A RunPod account with credit and an API key.
- A Hugging Face account with access to the gated repository [orcarouter/OrcaSAQ-2-Cyber-27B-Uncensored-GGUF](https://huggingface.co/orcarouter/OrcaSAQ-2-Cyber-27B-Uncensored-GGUF), and its token in `~/.cache/huggingface/token` (or in `HF_TOKEN`). RunPod uses the token to copy the model.
- `bash`, `curl` and `python3` on your computer.
- Optional: `jq` for the examples, [Bun](https://bun.sh) for the chat tool, `runpodctl` for the worker logs.

## Install

1. Get the repository:

   ```bash
   git clone https://github.com/kaoscodes/cyber-defense.git
   cd cyber-defense
   ```

2. Make the env file and write your RunPod API key in it:

   ```bash
   cp .env.example .env
   ```

3. Deploy:

   ```bash
   ./scripts/deploy.sh
   ```

   The script creates a template and a load-balancing endpoint. It writes `RUNPOD_ENDPOINT_ID`, `RUNPOD_TEMPLATE_ID` and `OPENAI_BASE_URL` to `.env`.

4. Send a first request (see [Run](#run)). RunPod must first copy the image and the model files to a GPU machine. Thus the first request can take 10 minutes or more. If it fails, send it again.

Git ignores `.env`. Do not commit it.

## Run

The API key is your RunPod API key. The server has one model, so the `model` value can be any text.

### Text

```bash
set -a; . ./.env; set +a
curl -sN "$OPENAI_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"cyberorca","stream":true,"reasoning_effort":"low","max_tokens":2000,
       "messages":[{"role":"user","content":"Is MD5 safe for password hashing?"}]}' \
| jq --unbuffered -Rrj '
    select(startswith("data: {")) | .[6:] | fromjson | .choices[0].delta // {} |
    (.reasoning_content // empty | "\u001b[2m" + . + "\u001b[0m"), (.content // empty)'
```

The command shows the reasoning in gray, then the answer.

With the OpenAI Python client:

```python
import os
from openai import OpenAI

client = OpenAI(base_url=os.environ["OPENAI_BASE_URL"], api_key=os.environ["RUNPOD_API_KEY"])
r = client.chat.completions.create(
    model="cyberorca",
    reasoning_effort="medium",
    messages=[{"role": "user", "content": "Audit this diff: ..."}],
)
print(r.choices[0].message.content)
print(r.choices[0].message.reasoning_content)  # the reasoning of the model
```

### Image

```bash
set -a; . ./.env; set +a
IMG=$(base64 < image.png | tr -d '\n')
jq -n --arg img "data:image/png;base64,$IMG" '{
  model: "cyberorca", max_tokens: 2000,
  messages: [{role: "user", content: [
    {type: "text", text: "Describe this image."},
    {type: "image_url", image_url: {url: $img}}
  ]}]
}' | curl -s "$OPENAI_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" -d @- \
  | jq -r '.choices[0].message.content'
```

### Request rules

- Set `reasoning_effort` to `low`, `medium` or `xhigh`. The chat template rejects other values. If you do not set it, the model uses `xhigh`. `xhigh` is slow and uses many tokens.
- `max_tokens` includes the reasoning tokens. Set a value that is large enough for the reasoning and the answer.
- To stop the reasoning, send `"chat_template_kwargs": {"enable_thinking": false}`.
- llama.cpp parameters work, for example `top_k`, `min_p` and `seed`.
- An image uses one token for each area of 32 × 32 pixels. The maximum is 2,048 tokens for each image (approximately 1440 × 1440 pixels). The server makes larger images smaller. Thus an image larger than approximately 1536 pixels gives no more detail.
- After a period with no requests, the first request waits for a worker. See [Cold start](#cold-start). Use a long timeout and retry on 5xx errors.

### Chat tool

The `tester/` directory contains a command-line chat. It uses Bun and the Vercel AI SDK. It streams the reasoning and the answer, and it keeps the chat history. After each answer, it shows the time to the first token, the speed, and the acceptance rate of the draft tokens.

```bash
cd tester && bun install
bun run chat                                # interactive chat
bun run chat "explain SSRF in 3 sentences"  # one question
bun run chat --effort xhigh --tools         # all options: --help
```

In the chat, type `/reset` to clear the history and `/exit` to stop. Push Ctrl+C to stop an answer.

## Use in pi

1. Add the provider `runpod-cyberorca` to `~/.pi/agent/models.json`. The guide [docs/pi.md](docs/pi.md) contains the full block and an explanation of each setting.
2. Start pi with the model:

   ```bash
   pi --model runpod-cyberorca/cyberorca-vision
   pi --model runpod-cyberorca/cyberorca-vision @screenshot.png "What does this page show?"
   ```

The guide also shows how to make it the default model, how to set the reasoning level, and how to solve problems.

## Use in other tools

### Claude Code

llama-server also has the Anthropic Messages API. Use the base URL without `/v1`:

```bash
set -a; . ./.env; set +a
ANTHROPIC_BASE_URL=https://$RUNPOD_ENDPOINT_ID.api.runpod.ai \
ANTHROPIC_AUTH_TOKEN=$RUNPOD_API_KEY \
ANTHROPIC_MODEL=cyberorca ANTHROPIC_DEFAULT_HAIKU_MODEL=cyberorca \
CLAUDE_CODE_SUBAGENT_MODEL=cyberorca \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 API_TIMEOUT_MS=600000 \
claude
```

Claude Code shows a warning that it does not know the model. You can ignore it.

### omp (oh-my-pi)

Add this provider to `~/.omp/agent/models.yml`, below `providers:`. Then run `omp --model runpod-cyberorca/cyberorca-vision`.

```yaml
  runpod-cyberorca:
    baseUrl: https://<endpoint-id>.api.runpod.ai/v1
    api: openai-completions
    apiKey: "!sed -n 's/^RUNPOD_API_KEY=//p' /path/to/cyber-defense/.env"
    compat:
      supportsDeveloperRole: false
      supportsReasoningEffort: true
      thinkingFormat: qwen
      qwenTemplateReasoningEffort: true
      reasoningEffortMap: { minimal: low, low: low, medium: medium, high: xhigh, xhigh: xhigh, max: xhigh }
      reasoningContentField: reasoning_content
      maxTokensField: max_tokens
    models:
      - id: cyberorca-vision
        name: CyberOrca 27B Vision (RunPod)
        reasoning: true
        input: [text, image]
        contextWindow: 262144
        maxTokens: 32768
        cost: { input: 0.09, output: 2, cacheRead: 0, cacheWrite: 0 }
```

## Benchmarks

Measured on 2026-11-11 with `./scripts/bench.sh`. One RTX 5090, one request at a time, `reasoning_effort` `low`, temperature 1.0 (model default), fixed seed. Each value is one run. The speeds are the values that llama-server reports.

| Workload | Result |
|---|---|
| Prompt processing, 55K tokens | 15.5 s (3,554 tok/s) |
| Generation: code | 225 tok/s |
| Generation: security review | 220 tok/s |
| Generation: chat | 148 tok/s |
| Generation with 55K tokens in context | 145 tok/s |

A request with one small image (980 × 312 pixels) takes 2.7 s in total. A request with a 4032 × 3024 photo takes 3.4 s in total, because the server makes the image smaller (see [Request rules](#request-rules)).

To run the benchmark on your endpoint:

```bash
./scripts/bench.sh                 # all workloads
SKIP_PREFILL=1 ./scripts/bench.sh  # generation workloads only
```

How to read the results:

- The speed changes with the GPU machine that RunPod selects. We measured differences of 10% to 15% between machines with the same GPU.
- The speed changes with the type of text. Speculative decoding helps most with code. It helps least with chat text.
- On a warm worker, llama-server keeps the prompt prefix in cache. Put the fixed instructions first and the changing text last. Then the next request processes only the new part.

These settings were measured one change at a time. Each made the endpoint faster:

- llama.cpp build b12242 in place of b12019: prompt processing 25% to 30% faster.
- Probabilistic draft sampling at temperature 1.0: generation 10% to 25% faster.
- A warm-up request when the worker starts: the first request is approximately 1 s faster.

These changes gave no more speed: n-gram speculative decoding together with the drafter, 8 CPU threads, sampling on the GPU, and a larger batch size.

## How it works

| Item | Value |
|---|---|
| Image | `ghcr.io/ggml-org/llama.cpp:server-cuda`, build b12242, pinned by digest. No changes to the image. |
| GPU | RTX 5090 (32 GB) first. RTX PRO 6000 if no 5090 is available. |
| Weights | CyberOrca, mixed IQ4_XS/Q5_K/Q6_K quantization (15.7 GB), and the BF16 vision projector |
| Context | 262,144 tokens for each request. KV cache quantized to q8_0. |
| Workers | 0 to 3. One request for each worker. A worker stops after 300 s with no requests. |
| Speculative decoding | DFlash2 with the [`z-lab/Qwen3.8-27B-DFlash2-GGUF`](https://huggingface.co/z-lab/Qwen3.8-27B-DFlash2-GGUF) drafter. 7 tokens for each draft. Probabilistic draft sampling. |

All settings are in `scripts/deploy.sh`.

**Speculative decoding.** A small draft model writes 7 tokens ahead. The main model checks these tokens in one step and keeps the correct ones. The output quality does not change, because the main model checks each token. With probabilistic draft sampling, the main model accepts the draft tokens by rejection sampling. At temperature 0, the output is the same byte for byte. At temperature 1.0, we compared 300 samples with and without speculative decoding and found no difference in the distribution.

**Model files.** RunPod model caching keeps the model, the vision projector and the drafter on the GPU machines. The workers do not download them from Hugging Face.

**Load-balancing endpoint.** RunPod sends each request directly to llama-server. A queue-based endpoint sends each token through the RunPod job queue. That limits streaming to approximately 20 tok/s.

**Health check.** The load balancer sends `GET /ping` to port 8081 of each worker. `scripts/health.pl` answers: 204 while the model loads, then 200. Before it answers 200, it sends one small request to llama-server. This warm-up request makes the first real request faster. The stock image contains perl, so the script needs no changes to the image.

**Sampling.** The GGUF file contains the values that Qwen recommends for thinking mode: temperature 1.0, top_k 20, top_p 0.95. It does not contain min_p, so `deploy.sh` sets min_p to 0, as Qwen recommends. A request can set other values.

**Chat template.** `scripts/chat-template.jinja` is the template of the model with one change. Claude Code sends a second system message after the first user message. The original template rejects this. The changed template shows such a message as a system turn.

**Vision.** The CyberOrca release contains only the text model. llama.cpp loads the image encoder and projector from a separate file (`LLAMA_ARG_MMPROJ`). We use the projector of the original Qwen3.8-27B (`mmproj-BF16.gguf` from `unsloth/Qwen3.8-27B-GGUF`). CyberOrca has the same text architecture as Qwen3.8-27B (same embedding size, vocabulary and M-RoPE sections), so the projector works without training. Tested on 2026-11-11: text in a screenshot (exact, including a 40-character token), a geometry problem from an image, object and place recognition.

## Cold start

A worker stops after 300 s with no requests. The time to the first token of the next request depends on what RunPod does:

| Case | Time to first token |
|---|---|
| RunPod resumes a worker that it stopped a short time ago (FlashBoot) | approximately 9 s |
| RunPod starts a new container | 30 s to 37 s |
| The GPU machine does not have the image or the model | some minutes |

When RunPod starts a new container, llama-server is ready 5 s to 10 s after the container starts. But the load balancer sends the first health check approximately 25 s after the container starts. This delay is in RunPod. The worker cannot decrease it.

Do not send `/ping` requests from the client during a cold start. In our test, the cold start became longer, and RunPod started a second worker.

## Cost

The RunPod API shows $1.19/hr for an RTX 5090 worker. Approximate raw cost when the GPU generates without stops:

| Item | Cost for 1M tokens |
|---|---|
| Output, code or review | ~$1.50 |
| Output, chat | ~$2.25 |
| Input (prompt processing) | ~$0.09 |

Other costs:

- A worker stays on for 300 s after the last request. Each period costs approximately $0.10.
- Reasoning tokens are output tokens.
- The RTX PRO 6000 has a higher price. If RunPod uses it, the cost for each token is higher.

## Limits

- A request can run for 5.5 minutes maximum.
- A request waits 2 minutes maximum for a worker.
- The load balancer has no queue. If all workers are busy, it rejects the request.
- The load balancer does not keep a chat on the same worker. If two workers run, a request can go to a worker that does not have the prompt in cache.
- A RunPod account has a limit of 5 workers for all endpoints together, unless RunPod increases it.

## Change the configuration

1. Change the settings in `scripts/deploy.sh`.
2. Update the template of the endpoint:

   ```bash
   ./scripts/deploy.sh update
   ```

3. Restart the workers. If workers run, the script stops, because their requests fail during a restart. Wait until the workers stop (5 minutes with no requests), or use `FORCE=1`.

   ```bash
   ./scripts/restart-workers.sh
   ```

4. Run `./scripts/bench.sh` and compare the results with [Benchmarks](#benchmarks).

After a change of the image, each GPU machine must copy the new image. The first start on each machine then takes some minutes.

To test a setting, use a second endpoint. Do not test on the endpoint that you use.

```bash
grep '^RUNPOD_API_KEY=' .env > .env.bench
ENV_FILE=.env.bench NAME=bench WORKERS_MAX=1 ./scripts/deploy.sh
ENV_FILE=.env.bench ./scripts/bench.sh
```

Delete the second endpoint in the RunPod console after the tests.

## Operations

```bash
set -a; . ./.env; set +a
runpodctl serverless logs $RUNPOD_ENDPOINT_ID --follow              # worker logs
runpodctl serverless update $RUNPOD_ENDPOINT_ID --workers-max 2     # change the scaling
./scripts/restart-workers.sh                                        # stop all workers
```

## Files

| File | Function |
|---|---|
| `scripts/deploy.sh` | Creates or updates the endpoint. Contains all settings. |
| `scripts/restart-workers.sh` | Stops all workers, so that new workers use the current template. |
| `scripts/bench.sh` | Measures prompt processing and generation speed. |
| `scripts/health.pl` | Health responder that runs in the worker. |
| `scripts/chat-template.jinja` | Chat template of the model, with the change for Claude Code. |
| `tester/` | Command-line chat tool. |
| `docs/pi.md` | Guide: how to use the endpoint in pi. |
