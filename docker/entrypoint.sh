#!/usr/bin/env bash
# Waits for the Ollama container, makes sure the model is pulled, then starts
# Claude Code through the ollama-claude launcher. Arguments are passed to claude.
set -euo pipefail

host="${OLLAMA_HOST:-http://ollama:11434}"
model="${OLLAMA_CLAUDE_MODEL:-qwen3.5}"

echo "==> Waiting for Ollama at $host" >&2
for _ in $(seq 1 60); do
  curl -fsS --max-time 2 "$host/api/version" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 2 "$host/api/version" >/dev/null 2>&1 \
  || { echo "error: Ollama is not reachable at $host" >&2; exit 1; }

# This image has no ollama CLI, so pull through the HTTP API.
case "$model" in
  *:cloud|*-cloud) ;;
  *)
    full="$model"; [[ "$full" == *:* ]] || full="$full:latest"
    if ! curl -fsS "$host/api/tags" | grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"$full\""; then
      echo "==> Pulling $model (first run only; this can take a while)" >&2
      curl -fsS -X POST "$host/api/pull" -d "{\"model\":\"$model\",\"stream\":false}" >/dev/null \
        || { echo "error: could not pull $model" >&2; exit 1; }
    fi
    ;;
esac

exec ollama-claude --host "$host" -m "$model" --no-pull -- "$@"
