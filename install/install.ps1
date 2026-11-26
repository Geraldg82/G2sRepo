<#
.SYNOPSIS
  One-command setup for Windows: installs Ollama and Claude Code if missing,
  starts Ollama, pulls a coding model, installs the ollama-claude launcher,
  and (optionally) launches Claude Code.

.EXAMPLE
  .\install\install.ps1
  .\install\install.ps1 -Model qwen3.5
  .\install\install.ps1 -CloudModel kimi-k2.7-code:cloud
  .\install\install.ps1 -NoLaunch -Yes
#>
[CmdletBinding()]
param(
  [string]$Model = $(if ($env:OLLAMA_CLAUDE_MODEL) { $env:OLLAMA_CLAUDE_MODEL } else { 'qwen3.5' }),
  [string]$CloudModel,
  [int]$Ctx = 65536,
  [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'ollama-claude'),
  [switch]$NoLaunch,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$RepoDir = Split-Path -Parent $PSScriptRoot
$ConfigDir = Join-Path $env:APPDATA 'ollama-claude'

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Warning $m }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Confirm-Step($q) {
  if ($Yes) { return $true }
  $r = Read-Host "$q [Y/n]"
  return ($r -eq '' -or $r -match '^[Yy]')
}
function Test-Ollama {
  try { Invoke-RestMethod -Uri 'http://localhost:11434/api/version' -TimeoutSec 3 | Out-Null; $true } catch { $false }
}
function Update-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

$Cloud = [bool]$CloudModel
if ($Cloud) { $Model = $CloudModel }

# 1. Ollama
if (Have 'ollama') {
  Info "Ollama already installed: $(ollama --version | Select-Object -Last 1)"
} else {
  if (-not (Confirm-Step 'Install Ollama from ollama.com?')) { throw 'Ollama is required' }
  if (Have 'winget') {
    Info 'Installing Ollama with winget'
    winget install --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements
  } else {
    Info 'Installing Ollama'
    Invoke-RestMethod https://ollama.com/install.ps1 | Invoke-Expression
  }
  Update-Path
  if (-not (Have 'ollama')) { throw "Ollama installed but not on PATH; open a new terminal and re-run" }
}

# 2. Claude Code
if (Have 'claude') {
  Info "Claude Code already installed: $(claude --version | Select-Object -First 1)"
} else {
  if (-not (Confirm-Step 'Install Claude Code?')) { throw 'Claude Code is required' }
  Info 'Installing Claude Code'
  Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
  Update-Path
  $local = Join-Path $env:USERPROFILE '.local\bin'
  if (Test-Path $local) { $env:Path = "$local;$env:Path" }
  if (-not (Have 'claude')) { throw "Claude Code installed but 'claude' is not on PATH; open a new terminal and re-run" }
}

# 3. Ollama server
if (Test-Ollama) {
  Info 'Ollama server is running'
} else {
  Info "Starting Ollama server (context length $Ctx)"
  $env:OLLAMA_CONTEXT_LENGTH = "$Ctx"
  Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
  $ok = $false
  for ($i = 0; $i -lt 40; $i++) { if (Test-Ollama) { $ok = $true; break }; Start-Sleep -Milliseconds 500 }
  if (-not $ok) { throw 'Ollama server did not start' }
}
# Persist the context length for future server starts (the Ollama app reads it too).
[Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', "$Ctx", 'User')

# 4. Model
if ($Cloud) {
  Info "Cloud model '$Model' selected; signing in to ollama.com"
  ollama signin
  if ($LASTEXITCODE -ne 0) { Warn "sign-in did not complete; run 'ollama signin' before launching" }
} else {
  Info "Pulling $Model (this can take a while)"
  ollama pull $Model
  if ($LASTEXITCODE -ne 0) { throw "could not pull $Model" }
}

# 5. Launcher + config
Info "Installing launcher to $Prefix"
New-Item -ItemType Directory -Force -Path $Prefix, $ConfigDir | Out-Null
Copy-Item (Join-Path $RepoDir 'bin\ollama-claude.ps1') (Join-Path $Prefix 'ollama-claude.ps1') -Force
Set-Content -Path (Join-Path $Prefix 'ollama-claude.cmd') -Encoding ASCII `
  -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0ollama-claude.ps1`" %*"
$cfg = Join-Path $ConfigDir 'config'
if (-not (Test-Path $cfg)) {
  Set-Content -Path $cfg -Value @("MODE=local", "MODEL=$Model", "CTX=$Ctx")
  Info "Wrote $cfg"
} else {
  Info "Keeping existing $cfg"
}
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $Prefix) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$Prefix", 'User')
  $env:Path = "$env:Path;$Prefix"
  Info "Added $Prefix to your user PATH (new terminals pick it up)"
}

Info "Done. Run 'ollama-claude' (or 'ollama launch claude') in any project folder."

# 6. Launch
if (-not $NoLaunch) {
  ollama launch --help *> $null
  if ($LASTEXITCODE -eq 0) {
    ollama launch claude --model $Model
  } else {
    & (Join-Path $Prefix 'ollama-claude.ps1') -Model $Model
  }
}
