###############################################################################
# setup-claude-nemotron-windows.ps1  (Windows 10/11)
#
# Installs Claude Code and wires it to NVIDIA NIM (Nemotron) through a local
# LiteLLM proxy, since Claude Code speaks the Anthropic API and NVIDIA NIM
# speaks the OpenAI-compatible API.
#
# Usage (PowerShell, run as your normal user):
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\setup-claude-nemotron-windows.ps1
#
# You will be asked for:
#   1) Your NVIDIA API key (starts with "nvapi-", free at https://build.nvidia.com)
#   2) The exact model ID (press Enter to accept the default)
###############################################################################

$ErrorActionPreference = "Stop"

$DefaultModel = "nvidia/llama-3.1-nemotron-ultra-253b-v1"
$ConfigDir    = Join-Path $env:USERPROFILE ".claude-nemotron"
$ProxyPort    = 4000

function Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "[ OK ] $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# ---------------------------------------------------------------- user input
$secureKey = Read-Host "Paste your NVIDIA API key (nvapi-...)" -AsSecureString
$NvidiaApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey))
if ([string]::IsNullOrWhiteSpace($NvidiaApiKey)) { Fail "API key cannot be empty." }
if (-not $NvidiaApiKey.StartsWith("nvapi-")) {
    Info "Key doesn't start with 'nvapi-' - continuing anyway, but double-check it."
}

$ModelId = Read-Host "Model ID [default: $DefaultModel]"
if ([string]::IsNullOrWhiteSpace($ModelId)) { $ModelId = $DefaultModel }

# ---------------------------------------------------------------- winget check
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Fail "winget is not available. Install 'App Installer' from the Microsoft Store, then re-run this script."
}

# ---------------------------------------------------------------- Node.js
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Info "Installing Node.js LTS via winget..."
    winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
    Refresh-Path
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Fail "Node.js installed but not on PATH yet. Close and reopen PowerShell, then re-run this script."
}
Ok "Node.js $(node --version) ready."

# ---------------------------------------------------------------- Claude Code
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Info "Installing Claude Code (@anthropic-ai/claude-code)..."
    npm install -g @anthropic-ai/claude-code
    Refresh-Path
}
Ok "Claude Code installed."

# ---------------------------------------------------------------- Python
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Info "Installing Python via winget..."
    winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
    Refresh-Path
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Fail "Python installed but not on PATH yet. Close and reopen PowerShell, then re-run this script."
}
Ok "Python ready."

# ---------------------------------------------------------------- LiteLLM in venv
Info "Installing LiteLLM proxy into a dedicated virtualenv..."
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
python -m venv (Join-Path $ConfigDir "venv")
$VenvPip     = Join-Path $ConfigDir "venv\Scripts\pip.exe"
$VenvLiteLLM = Join-Path $ConfigDir "venv\Scripts\litellm.exe"
& $VenvPip install --quiet --upgrade pip
& $VenvPip install --quiet "litellm[proxy]"
Ok "LiteLLM installed."

# ---------------------------------------------------------------- config files
Info "Writing LiteLLM config..."
@"
model_list:
  - model_name: nemotron
    litellm_params:
      model: nvidia_nim/$ModelId
      api_base: https://integrate.api.nvidia.com/v1
      api_key: os.environ/NVIDIA_NIM_API_KEY

litellm_settings:
  drop_params: true
"@ | Set-Content -Path (Join-Path $ConfigDir "litellm-config.yaml") -Encoding UTF8

@"
`$env:NVIDIA_NIM_API_KEY   = "$NvidiaApiKey"
`$env:ANTHROPIC_BASE_URL   = "http://localhost:$ProxyPort"
`$env:ANTHROPIC_AUTH_TOKEN = "local-proxy"
`$env:ANTHROPIC_MODEL      = "nemotron"
`$env:ANTHROPIC_SMALL_FAST_MODEL = "nemotron"
"@ | Set-Content -Path (Join-Path $ConfigDir "env.ps1") -Encoding UTF8

# ---------------------------------------------------------------- launchers
@"
. "$ConfigDir\env.ps1"
& "$VenvLiteLLM" --config "$ConfigDir\litellm-config.yaml" --port $ProxyPort
"@ | Set-Content -Path (Join-Path $ConfigDir "start-proxy.ps1") -Encoding UTF8

@"
. "$ConfigDir\env.ps1"
claude @args
"@ | Set-Content -Path (Join-Path $ConfigDir "claude-nemotron.ps1") -Encoding UTF8

Ok "Setup complete!"
Write-Host ""
Write-Host "─────────────────────────────────────────────────────────────"
Write-Host " HOW TO USE"
Write-Host "─────────────────────────────────────────────────────────────"
Write-Host " 1) In PowerShell window #1, start the proxy:"
Write-Host "      $ConfigDir\start-proxy.ps1"
Write-Host ""
Write-Host " 2) In PowerShell window #2, launch Claude Code on Nemotron:"
Write-Host "      $ConfigDir\claude-nemotron.ps1"
Write-Host ""
Write-Host " Config lives in: $ConfigDir"
Write-Host " To change the model, edit litellm-config.yaml (get exact"
Write-Host " model IDs from https://build.nvidia.com)."
Write-Host "─────────────────────────────────────────────────────────────"
