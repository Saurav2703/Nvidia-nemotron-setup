#!/usr/bin/env bash
###############################################################################
# setup-claude-nemotron-mac.sh  (macOS)
#
# Installs Claude Code and wires it to NVIDIA NIM (Nemotron) through a local
# LiteLLM proxy, since Claude Code speaks the Anthropic API and NVIDIA NIM
# speaks the OpenAI-compatible API.
#
# Usage:
#   chmod +x setup-claude-nemotron-mac.sh
#   ./setup-claude-nemotron-mac.sh
#
# You will be asked for:
#   1) Your NVIDIA API key (starts with "nvapi-", free at https://build.nvidia.com)
#   2) The exact model ID (press Enter to accept the default)
###############################################################################
set -euo pipefail

DEFAULT_MODEL="nvidia/llama-3.1-nemotron-ultra-253b-v1"
CONFIG_DIR="$HOME/.claude-nemotron"
PROXY_PORT=4000

info()  { printf "\033[1;34m[INFO]\033[0m %s\n"  "$1"; }
ok()    { printf "\033[1;32m[ OK ]\033[0m %s\n"  "$1"; }
fail()  { printf "\033[1;31m[FAIL]\033[0m %s\n"  "$1"; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "This script is for macOS. Use the .ps1 script on Windows."

# ---------------------------------------------------------------- user input
echo ""
read -r -s -p "Paste your NVIDIA API key (nvapi-...): " NVIDIA_API_KEY
echo ""
[[ -n "$NVIDIA_API_KEY" ]] || fail "API key cannot be empty."
[[ "$NVIDIA_API_KEY" == nvapi-* ]] || info "Key doesn't start with 'nvapi-' — continuing anyway, but double-check it."

read -r -p "Model ID [default: $DEFAULT_MODEL]: " MODEL_ID
MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL}"

# ---------------------------------------------------------------- Homebrew
if ! command -v brew >/dev/null 2>&1; then
  info "Homebrew not found. Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon or Intel
  if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  if [[ -x /usr/local/bin/brew   ]]; then eval "$(/usr/local/bin/brew shellenv)";   fi
fi
ok "Homebrew ready."

# ---------------------------------------------------------------- Node.js
if ! command -v node >/dev/null 2>&1; then
  info "Installing Node.js..."
  brew install node
fi
ok "Node.js $(node --version) ready."

# ---------------------------------------------------------------- Claude Code
if ! command -v claude >/dev/null 2>&1; then
  info "Installing Claude Code (@anthropic-ai/claude-code)..."
  npm install -g @anthropic-ai/claude-code
fi
ok "Claude Code installed: $(claude --version 2>/dev/null || echo 'installed')"

# ---------------------------------------------------------------- Python + LiteLLM
if ! command -v python3 >/dev/null 2>&1; then
  info "Installing Python..."
  brew install python
fi
info "Installing LiteLLM proxy into a dedicated virtualenv..."
mkdir -p "$CONFIG_DIR"
python3 -m venv "$CONFIG_DIR/venv"
"$CONFIG_DIR/venv/bin/pip" install --quiet --upgrade pip
"$CONFIG_DIR/venv/bin/pip" install --quiet "litellm[proxy]"
ok "LiteLLM installed."

# ---------------------------------------------------------------- config files
info "Writing LiteLLM config..."
cat > "$CONFIG_DIR/litellm-config.yaml" <<EOF
model_list:
  - model_name: nemotron
    litellm_params:
      model: nvidia_nim/${MODEL_ID}
      api_base: https://integrate.api.nvidia.com/v1
      api_key: os.environ/NVIDIA_NIM_API_KEY

litellm_settings:
  drop_params: true
EOF

# Store the key with restricted permissions
cat > "$CONFIG_DIR/env.sh" <<EOF
export NVIDIA_NIM_API_KEY="${NVIDIA_API_KEY}"
export ANTHROPIC_BASE_URL="http://localhost:${PROXY_PORT}"
export ANTHROPIC_AUTH_TOKEN="local-proxy"
export ANTHROPIC_MODEL="nemotron"
export ANTHROPIC_SMALL_FAST_MODEL="nemotron"
EOF
chmod 600 "$CONFIG_DIR/env.sh"

# ---------------------------------------------------------------- launcher
cat > "$CONFIG_DIR/start-proxy.sh" <<EOF
#!/usr/bin/env bash
source "$CONFIG_DIR/env.sh"
exec "$CONFIG_DIR/venv/bin/litellm" --config "$CONFIG_DIR/litellm-config.yaml" --port ${PROXY_PORT}
EOF
chmod +x "$CONFIG_DIR/start-proxy.sh"

cat > "$CONFIG_DIR/claude-nemotron.sh" <<EOF
#!/usr/bin/env bash
source "$CONFIG_DIR/env.sh"
exec claude "\$@"
EOF
chmod +x "$CONFIG_DIR/claude-nemotron.sh"

ok "Setup complete!"
echo ""
echo "─────────────────────────────────────────────────────────────"
echo " HOW TO USE"
echo "─────────────────────────────────────────────────────────────"
echo " 1) In terminal window #1, start the proxy:"
echo "      $CONFIG_DIR/start-proxy.sh"
echo ""
echo " 2) In terminal window #2, launch Claude Code on Nemotron:"
echo "      $CONFIG_DIR/claude-nemotron.sh"
echo ""
echo " Config lives in: $CONFIG_DIR"
echo " To change the model, edit litellm-config.yaml (get exact"
echo " model IDs from https://build.nvidia.com)."
echo "─────────────────────────────────────────────────────────────"
