#!/usr/bin/env bash
###############################################################################
# setup-claude-nemotron-gitbash.sh   (Windows + Git Bash)
#
# Configures Claude Code to use NVIDIA Nemotron through NVIDIA's
# OpenAI-compatible endpoint (https://integrate.api.nvidia.com/v1).
#
# Claude Code speaks the Anthropic API, and your endpoint speaks the OpenAI
# format, so a local LiteLLM proxy translates between them:
#
#     Claude Code -> LiteLLM (localhost:4000) -> integrate.api.nvidia.com/v1
#
# Usage (in Git Bash):
#   chmod +x setup-claude-nemotron-gitbash.sh
#   ./setup-claude-nemotron-gitbash.sh
#
# Prereqs it checks for (and tells you how to install if missing):
#   - Node.js  (winget install OpenJS.NodeJS.LTS)
#   - Python   (winget install Python.Python.3.12)
###############################################################################
set -euo pipefail

DEFAULT_MODEL="nvidia/nemotron-3-ultra-550b-a55b"
INVOKE_BASE="https://integrate.api.nvidia.com/v1"
CONFIG_DIR="$HOME/.claude-nemotron"
PROXY_PORT=4000

info()  { printf "\033[1;34m[INFO]\033[0m %s\n"  "$1"; }
ok()    { printf "\033[1;32m[ OK ]\033[0m %s\n"  "$1"; }
fail()  { printf "\033[1;31m[FAIL]\033[0m %s\n"  "$1"; exit 1; }

# Make sure we're actually in Git Bash / MSYS on Windows
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) : ;;
  *) info "This looks like a non-Windows shell. Continuing anyway, but this script targets Git Bash on Windows." ;;
esac

# ---------------------------------------------------------------- user input
echo ""
# Reuse NVIDIA_API_KEY from the environment if you already exported it
if [[ -n "${NVIDIA_API_KEY:-}" ]]; then
  info "Using NVIDIA_API_KEY already set in your environment."
else
  read -r -s -p "Paste your NVIDIA API key (nvapi-...): " NVIDIA_API_KEY
  echo ""
fi
[[ -n "$NVIDIA_API_KEY" ]] || fail "API key cannot be empty."
[[ "$NVIDIA_API_KEY" == nvapi-* ]] || info "Key doesn't start with 'nvapi-' — continuing anyway, double-check it."

read -r -p "Model ID [default: $DEFAULT_MODEL]: " MODEL_ID
MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL}"

# ---------------------------------------------------------------- Node.js + Claude Code
if ! command -v node >/dev/null 2>&1; then
  info "Node.js not found. Trying winget..."
  if command -v winget.exe >/dev/null 2>&1; then
    winget.exe install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements || true
    fail "Node.js was just installed. CLOSE this Git Bash window, open a NEW one, and re-run this script so PATH picks it up."
  else
    fail "Install Node.js LTS from https://nodejs.org, then re-run this script in a new Git Bash window."
  fi
fi
ok "Node.js $(node --version) ready."

if ! command -v claude >/dev/null 2>&1; then
  info "Installing Claude Code (@anthropic-ai/claude-code)..."
  npm install -g @anthropic-ai/claude-code
fi
ok "Claude Code installed."

# ---------------------------------------------------------------- Python + LiteLLM
PYTHON_BIN=""
for c in python py python3; do
  if command -v "$c" >/dev/null 2>&1; then PYTHON_BIN="$c"; break; fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  info "Python not found. Trying winget..."
  if command -v winget.exe >/dev/null 2>&1; then
    winget.exe install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements || true
    fail "Python was just installed. CLOSE this Git Bash window, open a NEW one, and re-run this script."
  else
    fail "Install Python from https://python.org (check 'Add to PATH'), then re-run in a new Git Bash window."
  fi
fi
ok "Python found ($PYTHON_BIN)."

info "Installing LiteLLM proxy into a dedicated virtualenv..."
mkdir -p "$CONFIG_DIR"
"$PYTHON_BIN" -m venv "$CONFIG_DIR/venv"

# Windows venvs put binaries in Scripts/, not bin/
if [[ -x "$CONFIG_DIR/venv/Scripts/pip.exe" ]]; then
  VENV_PIP="$CONFIG_DIR/venv/Scripts/pip.exe"
  VENV_LITELLM="$CONFIG_DIR/venv/Scripts/litellm.exe"
else
  VENV_PIP="$CONFIG_DIR/venv/bin/pip"
  VENV_LITELLM="$CONFIG_DIR/venv/bin/litellm"
fi
"$VENV_PIP" install --quiet --upgrade pip
"$VENV_PIP" install --quiet "litellm[proxy]"
ok "LiteLLM installed."

# ---------------------------------------------------------------- config files
info "Writing LiteLLM config..."
cat > "$CONFIG_DIR/litellm-config.yaml" <<EOF
model_list:
  - model_name: nemotron
    litellm_params:
      model: openai/${MODEL_ID}
      api_base: ${INVOKE_BASE}
      api_key: os.environ/NVIDIA_API_KEY
      max_tokens: 16384

litellm_settings:
  drop_params: true
EOF

cat > "$CONFIG_DIR/env.sh" <<EOF
export NVIDIA_API_KEY="${NVIDIA_API_KEY}"
export ANTHROPIC_BASE_URL="http://localhost:${PROXY_PORT}"
export ANTHROPIC_AUTH_TOKEN="local-proxy"
export ANTHROPIC_MODEL="nemotron"
export ANTHROPIC_SMALL_FAST_MODEL="nemotron"
EOF
chmod 600 "$CONFIG_DIR/env.sh"

# ---------------------------------------------------------------- launchers
cat > "$CONFIG_DIR/start-proxy.sh" <<EOF
#!/usr/bin/env bash
source "\$HOME/.claude-nemotron/env.sh"
exec "$VENV_LITELLM" --config "\$HOME/.claude-nemotron/litellm-config.yaml" --port ${PROXY_PORT}
EOF
chmod +x "$CONFIG_DIR/start-proxy.sh"

cat > "$CONFIG_DIR/claude-nemotron.sh" <<EOF
#!/usr/bin/env bash
source "\$HOME/.claude-nemotron/env.sh"
exec claude "\$@"
EOF
chmod +x "$CONFIG_DIR/claude-nemotron.sh"

# ---------------------------------------------------------------- smoke test
info "Testing your key against the NVIDIA endpoint (non-streaming, 1 short reply)..."
HTTP_CODE=$(curl -sS -o "$CONFIG_DIR/last-test.json" -w "%{http_code}" \
  --request POST \
  --url "${INVOKE_BASE}/chat/completions" \
  --header "Authorization: Bearer ${NVIDIA_API_KEY}" \
  --header "Content-Type: application/json" \
  --data "{\"model\": \"${MODEL_ID}\", \"messages\": [{\"role\":\"user\",\"content\":\"Say OK\"}], \"max_tokens\": 10, \"stream\": false}" ) || true

if [[ "$HTTP_CODE" == "200" ]]; then
  ok "API key and model ID verified against NVIDIA (HTTP 200)."
else
  info "Test call returned HTTP ${HTTP_CODE}. Response saved to $CONFIG_DIR/last-test.json"
  info "Common causes: wrong model ID, expired key, or exhausted free credits. Setup files were still written."
fi

ok "Setup complete!"
echo ""
echo "─────────────────────────────────────────────────────────────"
echo " HOW TO USE (Git Bash)"
echo "─────────────────────────────────────────────────────────────"
echo " 1) Git Bash window #1 - start the proxy:"
echo "      ~/.claude-nemotron/start-proxy.sh"
echo ""
echo " 2) Git Bash window #2 - launch Claude Code on Nemotron:"
echo "      ~/.claude-nemotron/claude-nemotron.sh"
echo ""
echo " Change model later: edit ~/.claude-nemotron/litellm-config.yaml"
echo " then restart the proxy."
echo "─────────────────────────────────────────────────────────────"
