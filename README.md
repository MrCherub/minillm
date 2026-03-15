# minillm

`minillm` is a small Zig CLI for talking to your Ollama models with a Nord-themed terminal UI.

It keeps the first version simple:
- `minillm` opens interactive chat
- `minillm ask "..."` sends a one-shot prompt
- `minillm models` lists available models
- uses local `ollama` if installed
- otherwise falls back to your Mac mini over SSH

## How It Works

`minillm` is just the client, not the model.

- Your MacBook runs the Zig CLI and handles the terminal UI.
- If `ollama` exists locally, `minillm` talks to it directly.
- If local `ollama` is missing, `minillm` SSHes into your Mac mini and runs Ollama there.
- The Mac mini does the actual inference.
- The response is streamed back to your MacBook terminal.

So the split is:

- MacBook Pro: CLI, prompt input, output formatting
- Mac mini: model execution through Ollama

## Launch

```sh
minillm
minillm ask "Explain tangent spaces simply."
minillm models
minillm --model jj-code ask "Write a zsh one-liner to list PDFs."
```

## Defaults

- model: `jj-general`
- SSH fallback host: `user@example-host`
- remote ollama path: `/Applications/Ollama.app/Contents/Resources/ollama`

Override with env vars:

```sh
export MINILLM_MODEL=jj-code
export MINILLM_REMOTE_HOST=user@example-host
export MINILLM_REMOTE_OLLAMA=/Applications/Ollama.app/Contents/Resources/ollama
```

## Notes

- `minillm` is written in Zig.
- The default remote model is `jj-general`.
- Set `MINILLM_REMOTE_HOST` locally to your actual Mac mini host.
- The SSH fallback path shell-quotes prompts correctly, so apostrophes in questions work.
