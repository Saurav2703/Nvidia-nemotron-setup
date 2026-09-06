#!/usr/bin/env bash
###############################################################################
# fix-codex-nemotron-wireapi.sh   (Windows + Git Bash)
#
# Fixes: "Error loading config.toml: `wire_api = "chat"` is no longer
#         supported. Set `wire_api = "responses"`"
#
# Newer Codex CLI versions only speak the OpenAI *Responses* API.
# This script:
#   1) Tests whether NVIDIA's endpoint supports /v1/responses directly.
#      -> If YES: rewrites ~/.codex/config.toml with wire_api="responses". Done.
#   2) If NOT: installs a local LiteLLM proxy that exposes a Responses API
#      and translates to NVIDIA's /chat/completions:
#
#         Codex (responses) -> http://localhost:4000/v1 -> NVIDIA (chat)
#
# Usage (Git Bash):
#   chmod +x fix-codex-nemotron-wireapi.sh
#   ./fix-codex-nemotron-wireapi.sh
###############################################################################
set -euo pipefail

DEFAULT_MODEL="nvidia/nemotron-3-ultra-550b-a55b"
NVIDIA_BASE="https://integrate.api.nvidia.com/v1"
CODEX_HOME="$HOME/.codex"
LAUNCH_DIR="$HOME/.codex-nemotron"
PROXY_PORT=4000

info()  { printf "\033[1;34m[INFO]\033[0m %s\n"  "$1"; }
ok()    { printf "\033[1;32m[ OK ]\033[0m %s\n"  "$1"; }
fail()  { printf "\033[1;31m[FAIL]\033[0m %s\n"  "$1"; exit 1; }

# ---------------------------------------------------------------- inputs
echo ""
if [[ -n "${NVIDIA_API_KEY:-}" ]]; then
  info "Using NVIDIA_API_KEY from your environment."
elif [[ -f "$LAUNCH_DIR/env.sh" ]]; then
  # Reuse the key saved by the previous setup script
  # shellcheck disable=SC1090
  source "$LAUNCH_DIR/env.sh"
  info "Loaded NVIDIA_API_KEY from $LAUNCH_DIR/env.sh"
else
  read -r -s -p "Paste your NVIDIA API key (nvapi-...): " NVIDIA_API_KEY
  echo ""
fi
[[ -n "${NVIDIA_API_KEY:-}" ]] || fail "API key cannot be empty."

read -r -p "Model ID [default: $DEFAULT_MODEL]: " MODEL_ID
MODEL_ID="${MODEL_ID:-$DEFAULT_MODEL}"

mkdir -p "$CODEX_HOME" "$LAUNCH_DIR"
cat > "$LAUNCH_DIR/env.sh" <<EOF
export NVIDIA_API_KEY="${NVIDIA_API_KEY}"
EOF
chmod 600 "$LAUNCH_DIR/env.sh"

backup_config() {
  if [[ -f "$CODEX_HOME/config.toml" ]]; then
    cp "$CODEX_HOME/config.toml" "$CODEX_HOME/config.toml.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

# ---------------------------------------------------------------- step 1: does NVIDIA speak Responses API?
info "Testing whether NVIDIA supports the Responses API directly..."
HTTP_CODE=$(curl -sS -o "$LAUNCH_DIR/responses-test.json" -w "%{http_code}" \
  --request POST \
  --url "${NVIDIA_BASE}/responses" \
  --header "Authorization: Bearer ${NVIDIA_API_KEY}" \
  --header "Content-Type: application/json" \
  --data "{\"model\": \"${MODEL_ID}\", \"input\": \"Say OK\", \"max_output_tokens\": 16}" ) || true

if [[ "$HTTP_CODE" == "200" ]]; then
  ok "NVIDIA supports /v1/responses directly (HTTP 200). No proxy needed!"
  backup_config
  cat > "$CODEX_HOME/config.toml" <<EOF
model = "${MODEL_ID}"
model_provider = "nvidia"

[model_providers.nvidia]
name = "NVIDIA NIM"
base_url = "${NVIDIA_BASE}"
env_key = "NVIDIA_API_KEY"
wire_api = "responses"
EOF
  ok "Rewrote $CODEX_HOME/config.toml with wire_api=\"responses\"."
  echo ""
  echo " Launch as before:  ~/.codex-nemotron/codex-nemotron.sh"
  exit 0
fi

info "NVIDIA returned HTTP ${HTTP_CODE} for /responses (details: $LAUNCH_DIR/responses-test.json)."
info "Falling back to a local LiteLLM proxy that translates Responses -> Chat Completions."

# ---------------------------------------------------------------- step 2: LiteLLM proxy fallback
PYTHON_BIN=""
for c in python py python3; do
  if command -v "$c" >/dev/null 2>&1; then PYTHON_BIN="$c"; break; fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v winget.exe >/dev/null 2>&1; then
    winget.exe install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements || true
    fail "Python was just installed. CLOSE this Git Bash window, open a NEW one, and re-run this script."
  fi
  fail "Install Python from https://python.org (check 'Add to PATH'), then re-run in a new Git Bash window."
fi

info "Installing LiteLLM into a virtualenv (this can take a minute)..."
"$PYTHON_BIN" -m venv "$LAUNCH_DIR/venv"
if [[ -x "$LAUNCH_DIR/venv/Scripts/pip.exe" ]]; then
  VENV_PIP="$LAUNCH_DIR/venv/Scripts/pip.exe"
  VENV_LITELLM="$LAUNCH_DIR/venv/Scripts/litellm.exe"
else
  VENV_PIP="$LAUNCH_DIR/venv/bin/pip"
  VENV_LITELLM="$LAUNCH_DIR/venv/bin/litellm"
fi
"$VENV_PIP" install --quiet --upgrade pip
"$VENV_PIP" install --quiet "litellm[proxy]"
ok "LiteLLM installed."

cat > "$LAUNCH_DIR/litellm-config.yaml" <<EOF
model_list:
  - model_name: ${MODEL_ID}
    litellm_params:
      model: openai/${MODEL_ID}
      api_base: ${NVIDIA_BASE}
      api_key: os.environ/NVIDIA_API_KEY
      max_tokens: 16384

litellm_settings:
  drop_params: true
EOF

backup_config
cat > "$CODEX_HOME/config.toml" <<EOF
model = "${MODEL_ID}"
model_provider = "nvidia_proxy"

[model_providers.nvidia_proxy]
name = "NVIDIA via LiteLLM"
base_url = "http://localhost:${PROXY_PORT}/v1"
env_key = "NVIDIA_API_KEY"
wire_api = "responses"
EOF
ok "Rewrote $CODEX_HOME/config.toml to point at the local proxy."

cat > "$LAUNCH_DIR/start-proxy.sh" <<EOF
#!/usr/bin/env bash
source "\$HOME/.codex-nemotron/env.sh"
exec "$VENV_LITELLM" --config "\$HOME/.codex-nemotron/litellm-config.yaml" --port ${PROXY_PORT}
EOF
chmod +x "$LAUNCH_DIR/start-proxy.sh"

cat > "$LAUNCH_DIR/codex-nemotron.sh" <<EOF
#!/usr/bin/env bash
source "\$HOME/.codex-nemotron/env.sh"
exec codex "\$@"
EOF
chmod +x "$LAUNCH_DIR/codex-nemotron.sh"

ok "Fix complete!"
echo ""
echo "─────────────────────────────────────────────────────────────"
echo " HOW TO USE (proxy mode)"
echo "─────────────────────────────────────────────────────────────"
echo " 1) Git Bash window #1 - start the proxy:"
echo "      ~/.codex-nemotron/start-proxy.sh"
echo ""
echo " 2) Git Bash window #2 - launch Codex on Nemotron:"
echo "      ~/.codex-nemotron/codex-nemotron.sh"
echo ""
echo " If Codex still errors, check your LiteLLM version supports"
echo " the /v1/responses route:  $VENV_PIP install -U 'litellm[proxy]'"
echo "─────────────────────────────────────────────────────────────"
