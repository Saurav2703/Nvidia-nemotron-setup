# Claude Code + NVIDIA Nemotron (free NIM API) — Setup Guide

## How it works

Claude Code talks the **Anthropic API** format. NVIDIA's free NIM endpoint talks the **OpenAI-compatible** format. So the scripts install a small local translator (LiteLLM proxy) between them:

```
Claude Code  →  LiteLLM proxy (http://localhost:4000)  →  NVIDIA NIM (Nemotron)
```

## Step 1 — Get your free NVIDIA API key (manual, ~2 minutes)

API keys can't be created by a script — you must do this once in a browser:

1. Go to https://build.nvidia.com and sign in / create a free account.
2. Find the Nemotron model you want (e.g. search "nemotron"). Open its page.
3. Click **"Get API Key"** (or "Generate Key"). Copy the key — it starts with `nvapi-`.
4. On the same page, copy the exact **model ID** (e.g. `nvidia/llama-3.1-nemotron-ultra-253b-v1`). If a newer "Nemotron 3 Ultra" model exists, use its exact ID from that page.

The free tier gives you a limited number of credits/requests per account.

## Step 2 — Run the setup script

**macOS** (Terminal):
```bash
chmod +x setup-claude-nemotron-mac.sh
./setup-claude-nemotron-mac.sh
```

**Windows** (PowerShell):
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\setup-claude-nemotron-windows.ps1
```

The script asks for your `nvapi-` key and the model ID, then installs Node.js, Claude Code, Python, and LiteLLM, and writes all config to `~/.claude-nemotron`.

## Step 3 — Use it

1. **Terminal/PowerShell window #1** — start the proxy:
   - macOS: `~/.claude-nemotron/start-proxy.sh`
   - Windows: `%USERPROFILE%\.claude-nemotron\start-proxy.ps1`
2. **Window #2** — launch Claude Code wired to Nemotron:
   - macOS: `~/.claude-nemotron/claude-nemotron.sh`
   - Windows: `%USERPROFILE%\.claude-nemotron\claude-nemotron.ps1`

Running plain `claude` (without the wrapper) still uses your normal Anthropic account — the Nemotron routing only applies when launched via the wrapper script.

## Changing the model later

Edit `~/.claude-nemotron/litellm-config.yaml` and replace the model ID after `nvidia_nim/`, then restart the proxy.

## Caveats

- Claude Code's agentic features (tool calling, file edits) are tuned for Claude models. Nemotron may work noticeably worse or fail on some tool calls — this is a model limitation, not a script bug.
- The free NIM tier is rate-limited; long coding sessions can exhaust credits.
- Your API key is stored in plain text at `~/.claude-nemotron/env.sh` (mac, permissions 600) or `env.ps1` (Windows). Delete that folder to remove it.
- Official Claude Code docs: https://docs.claude.com/en/docs/claude-code/overview
