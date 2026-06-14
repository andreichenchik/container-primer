# Agent instructions

This is an exploration of Apple's [Containerization](https://github.com/apple/containerization)
framework. Keep changes simple and incremental.

## Running the binary

- The binary's stdout is block-buffered when not attached to a tty, so running it in the
  background with `>log &` shows nothing until it exits. To capture the startup output (the
  server URL) when running non-interactively, wrap it in a pty: `script -q /tmp/log ./.build/debug/ContainerPrimer`.

## Before committing

- Keep `README.md` up to date. If a change affects how the project is built, run, or what it
  does, update `README.md` in the same commit.
