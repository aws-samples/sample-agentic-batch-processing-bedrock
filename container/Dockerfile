# Worker image: the agent CLI, its dependencies, and its logic, all resolved at
# build time. Nothing is installed at run time, because these containers have no
# route to a package registry. A fully build-time image also gives you
# byte-identical workers and a reproducible artifact to point at when a result is
# questioned.
FROM public.ecr.aws/docker/library/python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
      unzip \
      ca-certificates \
      git \
      bash \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI: the worker script uses it for S3 and DynamoDB.
RUN curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip \
 && aws --version

# The agent CLI. Replace this with your own agent's installation if you are
# adapting the pattern; the requirements are that it runs non-interactively,
# authenticates from the environment, and emits machine-readable output.
#
# The installer does not always put the binary on PATH for non-interactive
# shells, so link it explicitly and then prove it is reachable. Without the
# `claude --version` check, a broken install is not discovered until a job runs.
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && if   [ -x /root/.local/bin/claude ]; then ln -sf /root/.local/bin/claude /usr/local/bin/claude; \
    elif [ -x /root/.claude/bin/claude ]; then ln -sf /root/.claude/bin/claude /usr/local/bin/claude; \
    fi \
 && which claude \
 && claude --version

# Your agent logic: prompts, tool definitions, reference material. Loaded at run
# time with --plugin-dir, so it needs no installation step.
COPY agent-logic/ /opt/agent-logic/

COPY worker.sh /usr/local/bin/worker.sh
RUN chmod +x /usr/local/bin/worker.sh

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/worker.sh"]
