#!/usr/bin/env bash
# Deploys the model to RunPod Serverless as a load-balancing endpoint.
#
#   ./scripts/deploy.sh          Create the template and the endpoint.
#   ./scripts/deploy.sh update   Update the template of the endpoint that exists.
#
# The script reads RUNPOD_API_KEY from .env and writes the IDs of the new
# endpoint to the same file. Options (environment variables):
#
#   ENV_FILE      env file to use (default .env). Use a second file for a
#                 second endpoint, for example ENV_FILE=.env.bench.
#   NAME          endpoint name (default cyberorca-vision)
#   WORKERS_MAX   maximum number of workers (default 3)
#   HF_TOKEN      Hugging Face token. The default is the token in
#                 ~/.cache/huggingface/token. The model repository is gated:
#                 the account of the token must have access to it. RunPod
#                 checks the access only when it creates an endpoint. Thus a
#                 new gated model needs a new endpoint ("update" cannot add it).
#   MODEL_REF     other model weights, as repository@revision/file. Use it
#   MMPROJ_REF    for tests on a second endpoint. Example:
#                 MODEL_REF=unsloth/Qwen3.8-27B-GGUF@43f5.../Qwen3.8-27B-UD-IQ4_XS.gguf
#   GPU_POOL      RunPod GPU pools (default ADA_32_PRO,BLACKWELL_96). Use
#                 BLACKWELL_96 for weights that do not fit on an RTX 5090.
set -euo pipefail
cd "$(dirname "$0")/.."
export ENV_FILE="${ENV_FILE:-.env}"
set -a; . "./$ENV_FILE"; set +a
export ACTION="${1:-create}"
export NAME="${NAME:-cyberorca-vision}"
export WORKERS_MAX="${WORKERS_MAX:-3}"
export HF_TOKEN="${HF_TOKEN:-$(cat ~/.cache/huggingface/token 2>/dev/null || true)}"

exec python3 -I - <<'EOF'
import json, os, re, sys, urllib.error, urllib.request

env = os.environ
action = env["ACTION"]
if action not in ("create", "update"):
    sys.exit("usage: deploy.sh [update]")

# llama.cpp server image, build b12242. The digest pins the build.
IMAGE = "ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:a361e47e28e8801e290f3c855292e0f25047e5d8e998b0d101431f54db68e008"

# Hugging Face files: (repository, revision, file).
# CyberOrca (OrcaSAQ-2-Cyber-27B): Qwen3.8-27B with refusals removed. The
# repository is gated: the Hugging Face account of the token must have access.
MODEL = ("orcarouter/OrcaSAQ-2-Cyber-27B-Uncensored-GGUF", "06d9f1b87e8fdb5bc041f460b02a4effc7747293",
         "OrcaSAQ-2-27B-Uncensored.gguf")
# Vision projector of the original Qwen3.8-27B. CyberOrca has the same text
# architecture, so the projector works with it.
MMPROJ = ("unsloth/Qwen3.8-27B-GGUF", "43f522df59109a037f64f1e29ab1eff5c00e8e1e",
          "mmproj-BF16.gguf")
DRAFT = ("z-lab/Qwen3.8-27B-DFlash2-GGUF", "2d9571f8ce46e151f61c6499c99dee6079e1d610",
         "Qwen3.8-27B-DFlash2-Q4_K_M.gguf")

def override(var, default):
    if not env.get(var):
        return default
    repo, rest = env[var].split("@", 1)
    revision, filename = rest.split("/", 1)
    return (repo, revision, filename)

MODEL = override("MODEL_REF", MODEL)
MMPROJ = override("MMPROJ_REF", MMPROJ)
GPU_POOL = env.get("GPU_POOL") or "ADA_32_PRO,BLACKWELL_96"

# RunPod model caching puts the files at this path on each GPU machine.
def cached(repo, revision, name):
    return "/runpod-volume/huggingface-cache/hub/models--%s/snapshots/%s/%s" % (repo.replace("/", "--"), revision, name)

server_env = {
    "PORT": "80", "PORT_HEALTH": "8081",
    "LLAMA_ARG_HOST": "0.0.0.0", "LLAMA_ARG_PORT": "80",
    "LLAMA_ARG_STATIC_PATH": "/srv/www",
    "LLAMA_ARG_MODEL": cached(*MODEL),
    "LLAMA_ARG_MMPROJ": cached(*MMPROJ),  # image input
    # The server makes larger images smaller. Without this limit, a large
    # image uses all GPU memory on an RTX 5090 and the server stops.
    "LLAMA_ARG_IMAGE_MAX_TOKENS": "2048",
    # Speculative decoding. The main model checks each draft token, so the
    # output does not change.
    "LLAMA_ARG_SPEC_TYPE": "draft-dflash",
    "LLAMA_ARG_SPEC_DRAFT_MODEL": cached(*DRAFT),
    "LLAMA_ARG_SPEC_DRAFT_N_MAX": "7",
    # The drafter samples its tokens, and the model accepts them by rejection
    # sampling. The model accepts more draft tokens at temperature > 0.
    "LLAMA_ARG_SPEC_DRAFT_SAMPLING": "probabilistic",
    # Sampling. The GGUF sets the values that Qwen recommends for thinking
    # mode (temperature 1.0, top_k 20, top_p 0.95), but not min_p. Without
    # this line the server uses min_p 0.05. Qwen recommends 0.
    "LLAMA_ARG_MIN_P": "0",
    "LLAMA_ARG_CTX_SIZE": "262144", "LLAMA_ARG_N_PARALLEL": "1",
    "LLAMA_ARG_CACHE_TYPE_K": "q8_0", "LLAMA_ARG_CACHE_TYPE_V": "q8_0",
    "LLAMA_ARG_BATCH": "2048", "LLAMA_ARG_UBATCH": "2048",
    "LLAMA_ARG_N_GPU_LAYERS": "999", "LLAMA_ARG_FLASH_ATTN": "auto", "LLAMA_ARG_JINJA": "true",
    # The template of the model, with one change: a system message after the
    # first message becomes a system turn, not an error. Claude Code sends
    # such messages.
    "LLAMA_ARG_CHAT_TEMPLATE": open("scripts/chat-template.jinja").read(),
    # Health responder. The start command runs it with perl. See health.pl.
    "HEALTH_PL": open("scripts/health.pl").read(),
}
if env.get("HF_TOKEN"):
    server_env["HF_TOKEN"] = env["HF_TOKEN"]

template = {
    "imageName": IMAGE, "env": server_env,
    "ports": ["80/http", "8081/http"],
    "dockerEntrypoint": ["/bin/sh", "-c"],
    # The load balancer polls GET /ping on PORT_HEALTH. llama-server has no
    # /ping route, so health.pl answers. The loop starts it again if it stops.
    # The static "ping" file keeps /ping available on port 80 also.
    "dockerStartCmd": ["mkdir -p /srv/www && echo ok > /srv/www/ping; "
                       "(while :; do perl -e \"$HEALTH_PL\"; sleep 1; done) & exec /app/llama-server"],
}

HEADERS = {"Authorization": "Bearer " + env["RUNPOD_API_KEY"], "Content-Type": "application/json", "User-Agent": "deploy.sh"}

def call(url, method="POST", body=None):
    req = urllib.request.Request(url, method=method, headers=HEADERS, data=json.dumps(body).encode() if body is not None else None)
    try:
        return json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as err:
        sys.exit("%s %s failed: %s %s" % (method, url, err.code, err.read().decode()[:300]))

REST = "https://rest.runpod.io/v1"

if action == "update":
    template_id = env.get("RUNPOD_TEMPLATE_ID") or sys.exit("RUNPOD_TEMPLATE_ID is not set in " + env["ENV_FILE"])
    call(REST + "/templates/" + template_id, "PATCH", template)
    print("Template %s updated. New workers use it." % template_id)
    print("To restart all workers now, run ./scripts/restart-workers.sh")
    sys.exit(0)

if env.get("RUNPOD_ENDPOINT_ID"):
    sys.exit("%s already contains the endpoint %s.\nTo change it, run ./scripts/deploy.sh update\n"
             "To create a second endpoint, use a different ENV_FILE." % (env["ENV_FILE"], env["RUNPOD_ENDPOINT_ID"]))

template_id = call(REST + "/templates", "POST", {**template, "name": env["NAME"] + "-llamacpp", "isServerless": True, "containerDiskInGb": 20})["id"]
print("template:", template_id)

# The REST API cannot set the endpoint type. GraphQL saveEndpoint accepts "LB".
query = "mutation SaveEndpoint($input: EndpointInput!) { saveEndpoint(input: $input) { id } }"
result = call("https://api.runpod.io/graphql", "POST", {"query": query, "variables": {"input": {
    "name": env["NAME"], "type": "LB", "templateId": template_id,
    "gpuIds": GPU_POOL, "gpuCount": 1,
    "workersMin": 0, "workersMax": int(env["WORKERS_MAX"]), "idleTimeout": 300,
    "scalerType": "REQUEST_COUNT", "scalerValue": 1,
    "minCudaVersion": "12.8", "flashBootType": "FLASHBOOT",
    "modelReferences": ["https://huggingface.co/%s:%s" % (repo, revision) for repo, revision, _ in (MODEL, MMPROJ, DRAFT)],
}}})
if result.get("errors"):
    sys.exit("The template exists (%s), but RunPod did not create the endpoint: %s" % (template_id, result["errors"][0]["message"]))
endpoint_id = result["data"]["saveEndpoint"]["id"]
print("endpoint:", endpoint_id)

# RTX 5090 first. RTX PRO 6000 if no 5090 is available.
call(REST + "/endpoints/" + endpoint_id, "PATCH", {"gpuTypeIds": (["NVIDIA GeForce RTX 5090"] if "ADA_32_PRO" in GPU_POOL else []) + [
    "NVIDIA RTX PRO 6000 Blackwell Server Edition",
    "NVIDIA RTX PRO 6000 Blackwell Workstation Edition",
    "NVIDIA RTX PRO 6000 Blackwell Max-Q Workstation Edition",
]})

# Write the IDs to the env file.
values = {"RUNPOD_ENDPOINT_ID": endpoint_id, "RUNPOD_TEMPLATE_ID": template_id,
          "OPENAI_BASE_URL": "https://%s.api.runpod.ai/v1" % endpoint_id}
lines = [line for line in open(env["ENV_FILE"]).read().splitlines() if not re.match(r"\s*(%s)=" % "|".join(values), line)]
open(env["ENV_FILE"], "w").write("\n".join(lines + ["%s=%s" % item for item in values.items()]) + "\n")
print("Wrote the endpoint values to", env["ENV_FILE"])
print("The first request can take 10 minutes or more: RunPod must copy the image and the model to a GPU machine.")
EOF
