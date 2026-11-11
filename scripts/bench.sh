#!/usr/bin/env bash
# Measures prompt processing (time to first token) and generation speed.
# Usage: ./scripts/bench.sh [prompt_repeats]   (default 1100 ≈ 55K tokens)
#        SKIP_PREFILL=1 ./scripts/bench.sh       (generation workloads only)
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"  # ENV_FILE=.env.bench benchmarks a second endpoint
set -a; . "./$ENV_FILE"; set +a
N="${1:-1100}"

post() {
  curl -fsS --retry 5 --retry-all-errors --retry-delay 10 --max-time 900 \
    "$OPENAI_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" -d @-
}

# A unique first line defeats the prefix cache left over from earlier runs.
# Usage: long_prompt <run id> <max_tokens>
long_prompt() {
  python3 -I -c '
import json, sys
n = int(sys.argv[1])
code = "".join(f"def handler_{i}(req):\n    uid = req.args.get(\"id_{i}\")\n    q = \"SELECT * FROM t{i} WHERE id=\" + uid\n    return db.execute(q).fetchall()\n\n" for i in range(n))
print(json.dumps({"model": "x", "reasoning_effort": "low", "max_tokens": int(sys.argv[3]), "seed": 1, "messages": [
  {"role": "system", "content": f"run {sys.argv[2]}: You are a security auditor."},
  {"role": "user", "content": "Audit this code:\n" + code}]}))' "$N" "$1" "$2"
}

report='import json, sys
t = {"cache_n": 0, **json.load(sys.stdin)["timings"]}
t["prompt_s"] = t["prompt_ms"] / 1000
print("  prompt: {prompt_n} tokens in {prompt_s:.1f}s = {prompt_per_second:.0f} tok/s (cached {cache_n})".format(**t))
print("  gen:    {predicted_n} tokens = {predicted_per_second:.1f} tok/s".format(**t), end="")
if t.get("draft_n"): print("  (accepted {draft_n_accepted}/{draft_n} drafted tokens)".format(**t), end="")
print()'

echo "warm-up"
echo '{"model":"x","reasoning_effort":"low","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' | post > /dev/null

if [ -z "${SKIP_PREFILL:-}" ]; then
  RUN_ID=$(date +%s)
  echo "prefill (long prompt):"
  long_prompt "$RUN_ID" 1 | post | python3 -c "$report"
  # Same prompt again. This measures generation speed with a long context.
  # If only one worker runs, the prompt is in cache. If the load balancer
  # selects a different worker, that worker processes the prompt again.
  echo "generation with the long prompt in context:"
  long_prompt "$RUN_ID" 400 | post | python3 -c "$report"
fi

# Three output styles: speculative decoding gains depend heavily on content.
# The fixed seed makes two runs on the same configuration comparable.
gen() {
  echo "$1:"
  python3 -I -c 'import json, sys; print(json.dumps({"model": "x", "reasoning_effort": "low", "max_tokens": 1200, "seed": 1,
    "messages": [{"role": "user", "content": sys.argv[1]}]}))' "$2" | post | python3 -c "$report"
}
gen "code" "Write a Python Flask login endpoint with secure password hashing, CSRF protection and rate limiting."
gen "review" 'Security-review this code and quote each vulnerable line with a fix:
```python
@app.route("/download")
def download():
    name = request.args["file"]
    path = "/srv/files/" + name
    os.system("logger downloaded " + name)
    token = jwt.decode(request.cookies["t"], options={"verify_signature": False})
    if token["role"] == "admin":
        return send_file(path)
    q = f"SELECT owner FROM files WHERE name = '\''{name}'\''"
    if db.execute(q).fetchone()[0] == token["user"]:
        return send_file(path)
    return redirect(request.args.get("next", "/"))
```'
gen "chat" "Explain to a junior engineer how TLS certificate pinning works, when it is worth using on mobile apps, and the operational risks."
