#!/usr/bin/env bash
# Tests for bin/ollama-claude and docker/entrypoint.sh.
# Uses a fake Ollama API (tests/fake_ollama.py) and stub `claude`/`ollama`
# binaries, so no real Ollama, model or Anthropic account is needed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/bin/ollama-claude"
TMP="$(mktemp -d)"
PORT="${TEST_PORT:-18734}"
PASS=0
FAIL=0
SERVER_PID=""

cleanup() { [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Stub claude: prints the Anthropic env and its arguments.
mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "9.9.9 (Claude Code stub)"; exit 0; fi
echo "BASE_URL=${ANTHROPIC_BASE_URL-<unset>}"
echo "AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-<unset>}"
echo "API_KEY=${ANTHROPIC_API_KEY-<unset>}"
echo "ARGS=$*"
EOF
# Stub ollama: records pulls into the fake server via its API.
cat > "$TMP/bin/ollama" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "ollama version is 0.99.0-fake" ;;
  pull) echo "pull \$2" >> "$TMP/pulls"
        curl -fsS -X POST "http://127.0.0.1:$PORT/api/pull" -d "{\"model\":\"\$2\"}" >/dev/null ;;
  serve) echo "serve called" >> "$TMP/serve"; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/ollama"

start_server() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  python3 "$ROOT/tests/fake_ollama.py" "$PORT" "$1" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:$PORT/api/version" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "fake server failed to start"; exit 1
}

# Run the launcher in a clean environment.
run() {
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" \
    OLLAMA_CLAUDE_CONFIG="$TMP/config" OLLAMA_CLAUDE_START_TIMEOUT=1 \
    ${EXTRA_ENV:-} bash "$LAUNCHER" "$@" </dev/null 2>&1
}

check() { # name, expected-substring, actual
  if [[ "$3" == *"$2"* ]]; then
    PASS=$((PASS + 1)); echo "ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     expected to contain: $2"; echo "     got: ${3//$'\n'/$'\n'     }"
  fi
}
check_not() {
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS + 1)); echo "ok   $1"
  else FAIL=$((FAIL + 1)); echo "FAIL $1"; echo "     should not contain: $2"; echo "     got: $3"; fi
}

H="--host=127.0.0.1:$PORT"
start_server "qwen3.5:latest"

out="$(run --version)";                 check "version" "ollama-claude 0.1.0" "$out"
out="$(run --help)";                    check "help" "Usage:" "$out"
out="$(run --bogus)";                   check "unknown option" "unknown option '--bogus'" "$out"
out="$(run --ctx abc)";                 check "ctx must be numeric" "--ctx must be a number" "$out"

out="$(run $H -m qwen3.5)"
check "local: base url"   "BASE_URL=http://127.0.0.1:$PORT" "$out"
check "local: token"      "AUTH_TOKEN=ollama" "$out"
check "local: empty key"  "API_KEY=" "$out"
check_not "local: key not unset" "API_KEY=<unset>" "$out"
check "local: model arg"  "ARGS=--model qwen3.5" "$out"

out="$(run $H -m qwen3.5 -- -p "hello world")"
check "passthrough args" "ARGS=--model qwen3.5 -p hello world" "$out"

out="$(run $H)"
check "single model auto-picked" "ARGS=--model qwen3.5:latest" "$out"

rm -f "$TMP/pulls"
out="$(run $H -m gemma4)"
check "missing model is pulled" "pull gemma4" "$(cat "$TMP/pulls" 2>/dev/null)"
check "launch after pull" "ARGS=--model gemma4" "$out"

out="$(run $H -m llama9 --no-pull)"
check "--no-pull refuses" "not available" "$out"

rm -f "$TMP/pulls"
out="$(run $H -m kimi-k2.7-code:cloud)"
check "cloud-tagged model not pulled" "ARGS=--model kimi-k2.7-code:cloud" "$out"
[[ -f "$TMP/pulls" ]] && { FAIL=$((FAIL + 1)); echo "FAIL cloud-tagged model pulled"; } || { PASS=$((PASS + 1)); echo "ok   cloud-tagged model skipped pull"; }

out="$(run --cloud -m glm-5.3-flash)"
check "cloud needs key" "needs OLLAMA_API_KEY" "$out"
out="$(EXTRA_ENV="OLLAMA_API_KEY=sk-test" run --cloud -m glm-5.3-flash:cloud)"
check "cloud: base url" "BASE_URL=https://ollama.com" "$out"
check "cloud: token"    "AUTH_TOKEN=sk-test" "$out"
check "cloud: strips :cloud" "ARGS=--model glm-5.3-flash" "$out"
out="$(EXTRA_ENV="OLLAMA_API_KEY=sk-test" run --cloud -m glm-5.3-flash -n)"
check_not "dry run hides key" "sk-test" "$out"

out="$(EXTRA_ENV="ANTHROPIC_API_KEY=real" run --anthropic)"
check "anthropic: no base url" "BASE_URL=<unset>" "$out"
check "anthropic: keeps key"   "API_KEY=real" "$out"

out="$(run -n $H -m qwen3.5)"
check "dry run prints command" "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" "$out"
check_not "dry run does not launch" "ARGS=" "$out"

# Host normalisation
out="$(EXTRA_ENV="OLLAMA_HOST=0.0.0.0" run config)";           check "host 0.0.0.0" "HOST=http://localhost:11434" "$out"
out="$(EXTRA_ENV="OLLAMA_HOST=10.0.0.5" run config)";          check "host without port" "HOST=http://10.0.0.5:11434" "$out"
out="$(EXTRA_ENV="OLLAMA_HOST=https://gpu.lan:8443/" run config)"; check "host with scheme" "HOST=https://gpu.lan:8443" "$out"

# Config file and precedence
printf '# comment\nMODEL="from-config"\nCTX=32768\n' > "$TMP/config"
out="$(run config)";        check "config file model" "MODEL=from-config" "$out"
check "config file ctx" "CTX=32768" "$out"
out="$(EXTRA_ENV="OLLAMA_CLAUDE_MODEL=from-env" run config)"; check "env beats config" "MODEL=from-env" "$out"
out="$(EXTRA_ENV="OLLAMA_CLAUDE_MODEL=from-env" run config -m from-flag)"; check "flag beats env" "MODEL=from-flag" "$out"
rm -f "$TMP/config"

# Server down: remote host cannot be started; local host tries `ollama serve`.
out="$(run --host=10.255.255.1:1 -m x)"; check "remote server down" "not on this machine" "$out"
out="$(run --host=127.0.0.1:1 -m x)";    check "local server start attempted" "did not start" "$out"
check "ollama serve was called" "serve called" "$(cat "$TMP/serve" 2>/dev/null)"

# Two models + no tty: must ask for -m
start_server "a:latest,b:latest"
out="$(run $H)"; check "several models need -m" "pass one with -m" "$out"

# Settings override warning
mkdir -p "$TMP/home/.claude"
echo '{"env":{"ANTHROPIC_BASE_URL":"https://x"}}' > "$TMP/home/.claude/settings.json"
out="$(run $H -m a)"; check "settings override warning" "override this launcher" "$out"
out="$(run doctor $H)"; check "doctor warns on settings" "sets ANTHROPIC_* variables" "$out"
rm -f "$TMP/home/.claude/settings.json"

out="$(run doctor $H -m a)"
check "doctor: claude" "OK   Claude Code: 9.9.9" "$out"
check "doctor: server" "version 0.99.0-fake" "$out"
check "doctor: models" "2 model(s) available" "$out"
check "doctor: passes" "All required checks passed." "$out"
out="$(run models $H)"; check "models lists" $'a:latest\nb:latest' "$out"

# Docker entrypoint: pulls over HTTP, then hands off to the launcher.
start_server ""
cp "$LAUNCHER" "$TMP/bin/ollama-claude"
out="$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" OLLAMA_CLAUDE_CONFIG="$TMP/none" \
  OLLAMA_HOST="http://127.0.0.1:$PORT" OLLAMA_CLAUDE_MODEL=qwen3.5 \
  bash "$ROOT/docker/entrypoint.sh" -p hi </dev/null 2>&1)"
check "entrypoint pulls" "Pulling qwen3.5" "$out"
check "entrypoint launches" "ARGS=--model qwen3.5 -p hi" "$out"
check "entrypoint base url" "BASE_URL=http://127.0.0.1:$PORT" "$out"

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
