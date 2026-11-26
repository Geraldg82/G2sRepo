#!/usr/bin/env bash
# One-command setup for macOS and Linux:
#   installs Ollama and Claude Code if missing, starts Ollama,
#   pulls a coding model, installs the ollama-claude launcher,
#   and (optionally) launches Claude Code.
#
# Usage:
#   ./install/install.sh                    # default model, then launch
#   ./install/install.sh -m qwen3.5         # choose the model
#   ./install/install.sh --cloud-model kimi-k2.7-code:cloud
#   ./install/install.sh --no-launch        # set up only
#   ./install/install.sh --yes              # no prompts

set -euo pipefail

MODEL="${OLLAMA_CLAUDE_MODEL:-qwen3.5}"
CTX="65536"
LAUNCH=1
ASSUME_YES=0
PREFIX="${PREFIX:-$HOME/.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ollama-claude"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  -m, --model NAME        local model to pull (default: $MODEL)
      --cloud-model NAME  use an Ollama cloud model instead (runs 'ollama signin')
      --ctx N             context length for the Ollama server (default: $CTX)
      --prefix DIR        where to install the launcher (default: $PREFIX)
      --no-launch         do not start Claude Code at the end
  -y, --yes               do not ask for confirmation
  -h, --help              show this help
EOF
}

CLOUD=0
while (($#)); do
  case "$1" in
    -m|--model) MODEL="$2"; shift 2 ;;
    --cloud-model) MODEL="$2"; CLOUD=1; shift 2 ;;
    --ctx) CTX="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

confirm() {
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || return 0
  local reply
  read -r -p "$1 [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *) die "unsupported OS '$OS'. On Windows use install/install.ps1" ;;
esac
have curl || die "curl is required"

# 1. Ollama
if have ollama; then
  info "Ollama already installed: $(ollama --version 2>/dev/null | tail -1)"
else
  confirm "Install Ollama from ollama.com?" || die "Ollama is required"
  if [[ "$OS" == Darwin ]] && have brew; then
    info "Installing Ollama with Homebrew"
    brew install ollama
  else
    info "Installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
  fi
fi

# 2. Claude Code
export PATH="$HOME/.local/bin:$PATH"
if have claude; then
  info "Claude Code already installed: $(claude --version 2>/dev/null | head -1)"
else
  confirm "Install Claude Code?" || die "Claude Code is required"
  info "Installing Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
  have claude || die "Claude Code installed but 'claude' is not on PATH; open a new shell and re-run"
fi

# 3. Ollama server
if curl -fsS --max-time 3 http://localhost:11434/api/version >/dev/null 2>&1; then
  info "Ollama server is running"
else
  info "Starting Ollama server (context length $CTX)"
  mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/ollama-claude"
  OLLAMA_CONTEXT_LENGTH="$CTX" nohup ollama serve \
    >>"${XDG_STATE_HOME:-$HOME/.local/state}/ollama-claude/serve.log" 2>&1 &
  for _ in $(seq 1 40); do
    curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1 \
    || die "Ollama server did not start"
fi

# 4. Model
if ((CLOUD)); then
  info "Cloud model '$MODEL' selected; signing in to ollama.com"
  ollama signin || warn "sign-in did not complete; run 'ollama signin' before launching"
else
  info "Pulling $MODEL (this can take a while)"
  ollama pull "$MODEL"
fi

# 5. Launcher + config
info "Installing launcher to $PREFIX/bin/ollama-claude"
mkdir -p "$PREFIX/bin" "$CONFIG_DIR"
install -m 0755 "$REPO_DIR/bin/ollama-claude" "$PREFIX/bin/ollama-claude"
if [[ ! -f "$CONFIG_DIR/config" ]]; then
  printf 'MODE=local\nMODEL=%s\nCTX=%s\n' "$MODEL" "$CTX" > "$CONFIG_DIR/config"
  info "Wrote $CONFIG_DIR/config"
else
  info "Keeping existing $CONFIG_DIR/config"
fi
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) warn "$PREFIX/bin is not on your PATH; add: export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac

info "Done. Run 'ollama-claude' (or 'ollama launch claude') in any project folder."

# 6. Launch
if ((LAUNCH)) && [[ -t 0 ]]; then
  if have ollama && ollama launch --help >/dev/null 2>&1; then
    exec ollama launch claude --model "$MODEL"
  fi
  exec "$PREFIX/bin/ollama-claude" -m "$MODEL"
fi
