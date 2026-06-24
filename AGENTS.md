# Agent instructions

`agent-wrap` is a thin wrapper that runs a containerized agent in a sandboxed macOS VM, built on
Apple's [Containerization](https://github.com/apple/containerization) framework. Keep changes simple
and incremental.

- Keep `README.md` current and concise. Mention user-facing build/run/behavior changes, but avoid
  detailed implementation notes unless they are needed to use the project.
- When running the binary non-interactively, wrap it in a pty to capture the startup URL:
  `script -q /tmp/log ./.build/release/agent-wrap run --build-image example/image example/workspace`.
