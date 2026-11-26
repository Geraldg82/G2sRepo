# ollama-claude

Run [Claude Code](https://code.claude.com/docs/en/overview) on models served by
[Ollama](https://ollama.com), either open models on your own machine or Ollama's
cloud models, and switch back to Anthropic's API with one flag.

This repo has three parts:

| Part | What it does |
| --- | --- |
| **Installers** (`install/`) | One command installs Ollama and Claude Code, starts Ollama with a large enough context window, pulls a model, installs the launcher and starts Claude Code. |
| **Launcher** (`bin/ollama-claude`) | Picks a model, checks that Ollama is running (and starts it if not), pulls missing models, sets the right environment variables and opens Claude Code. Also switches between local Ollama, Ollama cloud and Anthropic. |
| **Docker** (`docker-compose.yml`) | Ollama and Claude Code in containers, the same on every machine. Optional NVIDIA GPU. |

> **Already have a recent Ollama?** `ollama launch claude` does the basic
> setup on its own. This repo adds the one-step install, a saved default model,
> automatic server start and model pull, cloud and Anthropic modes, a `doctor`
> check and a container setup.

## Quick start

**macOS / Linux**

```bash
git clone https://github.com/<you>/ollama-claude.git
cd ollama-claude
./install/install.sh                 # default model: qwen3.5
```

**Windows (PowerShell)**

```powershell
git clone https://github.com/<you>/ollama-claude.git
cd ollama-claude
powershell -ExecutionPolicy Bypass -File .\install\install.ps1
```

Useful installer options:

```bash
./install/install.sh -m qwen3-coder               # another local model
./install/install.sh --cloud-model kimi-k2.7-code:cloud   # cloud model, no big download
./install/install.sh --no-launch --yes            # set up only, no prompts
```

(PowerShell: `-Model`, `-CloudModel`, `-NoLaunch`, `-Yes`.)

## Using the launcher

After installing, run it from any project folder:

```bash
ollama-claude                         # use the saved model (or choose one)
ollama-claude -m qwen3.5              # pick a model for this run
ollama-claude -m kimi-k2.7-code:cloud # Ollama cloud model via your local Ollama
ollama-claude --cloud -m glm-5.3-flash   # straight to ollama.com, no local Ollama
ollama-claude --anthropic             # normal Claude Code on Anthropic's API
ollama-claude -- -p "explain this repo"  # everything after -- goes to claude
ollama-claude -n -m qwen3.5           # dry run: print what would run
ollama-claude doctor                  # check the setup
ollama-claude models                  # list pulled models
```

On Windows: `ollama-claude -Model qwen3.5`, `-Cloud`, `-Anthropic`,
`-DryRun`, `-Command doctor`.

### Modes

| Mode | Talks to | Needs |
| --- | --- | --- |
| `local` (default) | Ollama at `http://localhost:11434` (or `--host`) | Ollama installed or reachable |
| `cloud` | `https://ollama.com` | `OLLAMA_API_KEY` from [ollama.com/settings/keys](https://ollama.com/settings/keys) |
| `anthropic` | Anthropic's API | Your normal Claude login or API key |

In `local` and `cloud` modes the launcher sets, only for the Claude Code process:

```bash
ANTHROPIC_BASE_URL=http://localhost:11434   # or https://ollama.com
ANTHROPIC_AUTH_TOKEN=ollama                 # or $OLLAMA_API_KEY
ANTHROPIC_API_KEY=""
```

Your shell isn't changed, so a plain `claude` still uses Anthropic.

### Configuration

The installer writes `~/.config/ollama-claude/config` (Windows:
`%APPDATA%\ollama-claude\config`). See [`config.example`](config.example).
Command-line flags override environment variables, which override the config file:

| Config key | Environment variable | Flag |
| --- | --- | --- |
| `MODEL` | `OLLAMA_CLAUDE_MODEL` | `-m` |
| `MODE` | `OLLAMA_CLAUDE_MODE` | `--local` / `--cloud` / `--anthropic` |
| `HOST` | `OLLAMA_HOST` | `--host` |
| `CTX` | `OLLAMA_CLAUDE_CTX` | `--ctx` |

## Choosing a model

- **Local models** must support tool calling and need a **64k+ context window**
  for real repositories. The launcher starts Ollama with `OLLAMA_CONTEXT_LENGTH=65536`;
  if Ollama is already running (for example the desktop app), set the context
  length in the app's settings or restart it with that variable.
  Browse: [ollama.com/search?c=tools](https://ollama.com/search?c=tools).
- **Cloud models** (names ending in `:cloud`) run on Ollama's servers, so there's
  no big download or GPU needed. Run `ollama signin` once.
  Browse: [ollama.com/search?c=cloud](https://ollama.com/search?c=cloud).

Rough guide for local models: 16 GB of RAM or VRAM for small coding models,
32 GB or more for mid-size ones. Smaller models handle chat and simple edits but
struggle with long agentic tasks. Cloud models are the easy option on a laptop.

## Docker

```bash
docker compose run --rm claude                     # Claude Code on ./workspace
WORKSPACE=~/code/myproj docker compose run --rm claude
OLLAMA_CLAUDE_MODEL=qwen3-coder docker compose run --rm claude
docker compose run --rm claude -p "summarize this repo"   # one-shot

# NVIDIA GPU (needs the NVIDIA Container Toolkit):
docker compose -f docker-compose.yml -f docker-compose.gpu.yml run --rm claude
```

- The Ollama container keeps models in the `ollama-models` volume, so they're
  downloaded only once. It listens on `127.0.0.1:11434`, so the launcher on the host
  can use it too.
- Claude Code's settings and history are kept in the `claude-home` volume.
- `docker compose up -d` starts only Ollama; `docker compose down` stops it.
- On macOS, Docker can't use the Apple GPU. Run Ollama natively there
  (`install/install.sh`) and keep Docker for Linux/NVIDIA machines.

## Troubleshooting

Run `ollama-claude doctor` first.

| Symptom | Fix |
| --- | --- |
| Claude Code still uses Anthropic, or fails to log in | A `settings.json` (`~/.claude/` or the project's `.claude/`) sets `ANTHROPIC_*` variables, which override the launcher. Remove them. Inside Claude Code, `/status` shows the active endpoint. |
| The model forgets things or stops mid-task | The context window is too small. Use 64k+ (`--ctx`, or the Ollama app's settings). |
| "model does not support tools" | Choose a model with tool support ([list](https://ollama.com/search?c=tools)). |
| Cloud model fails with 401 | Run `ollama signin` (local mode) or check `OLLAMA_API_KEY` (cloud mode). |
| Web search and some advanced features don't work | Ollama supports a subset of Anthropic's API; see Ollama's [Anthropic compatibility](https://docs.ollama.com/api/anthropic-compatibility) page. |

## Development

```bash
bash tests/run.sh          # launcher + Docker entrypoint tests (fake Ollama, stub claude)
shellcheck -S warning bin/ollama-claude install/install.sh docker/entrypoint.sh tests/run.sh
```

CI runs the tests on Linux and macOS, checks the PowerShell scripts on Windows,
and builds the Docker image.
