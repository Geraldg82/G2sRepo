# Claude Code, preconfigured to talk to an Ollama server.
# Used by docker-compose.yml; the Ollama server runs in its own container.
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git less openssh-client procps ripgrep \
 && rm -rf /var/lib/apt/lists/*

ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd -g "${USER_GID}" coder \
 && useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash coder

USER coder
ENV PATH="/home/coder/.local/bin:${PATH}"
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

COPY --chown=coder:coder bin/ollama-claude /home/coder/.local/bin/ollama-claude
COPY --chown=coder:coder docker/entrypoint.sh /home/coder/.local/bin/entrypoint.sh

ENV OLLAMA_HOST=http://ollama:11434 \
    OLLAMA_CLAUDE_MODEL=qwen3.5 \
    DISABLE_AUTOUPDATER=1

WORKDIR /workspace
ENTRYPOINT ["entrypoint.sh"]
