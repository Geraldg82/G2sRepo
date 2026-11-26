<#
.SYNOPSIS
  Launch Claude Code against Ollama (local or cloud) or Anthropic. Windows version
  of bin/ollama-claude.

.EXAMPLE
  ollama-claude                          # pick a local model and launch
  ollama-claude -Model qwen3.5
  ollama-claude -Cloud -Model glm-5.3-flash
  ollama-claude -Anthropic
  ollama-claude -Command doctor
  ollama-claude -Model qwen3.5 -- -p "explain this repo"
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet('launch', 'doctor', 'models', 'config')]
  [string]$Command = 'launch',
  [string]$Model,
  [switch]$Cloud,
  [switch]$Anthropic,
  [string]$OllamaHost,
  [int]$Ctx = 0,
  [switch]$NoPull,
  [switch]$DryRun,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ClaudeArgs
)

$ErrorActionPreference = 'Stop'
$ConfigFile = if ($env:OLLAMA_CLAUDE_CONFIG) { $env:OLLAMA_CLAUDE_CONFIG } else { Join-Path $env:APPDATA 'ollama-claude\config' }
$LogDir = Join-Path $env:LOCALAPPDATA 'ollama-claude'

function Info($m) { [Console]::Error.WriteLine("==> $m") }
function Fail($m) { [Console]::Error.WriteLine("error: $m"); exit 1 }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

# Config file, then environment, then parameters.
$cfg = @{ MODE = 'local'; MODEL = ''; HOST = ''; CTX = '65536' }
if (Test-Path $ConfigFile) {
  foreach ($line in Get-Content $ConfigFile) {
    if ($line -match '^\s*([A-Z]+)\s*=\s*"?(.*?)"?\s*$' -and -not $line.TrimStart().StartsWith('#')) {
      $cfg[$Matches[1]] = $Matches[2]
    }
  }
}
if ($env:OLLAMA_CLAUDE_MODEL) { $cfg.MODEL = $env:OLLAMA_CLAUDE_MODEL }
if ($env:OLLAMA_CLAUDE_MODE)  { $cfg.MODE = $env:OLLAMA_CLAUDE_MODE }
if ($env:OLLAMA_CLAUDE_CTX)   { $cfg.CTX = $env:OLLAMA_CLAUDE_CTX }
if (-not $cfg.HOST -and $env:OLLAMA_HOST) { $cfg.HOST = $env:OLLAMA_HOST }

$Mode = $cfg.MODE
if ($Cloud) { $Mode = 'cloud' }
if ($Anthropic) { $Mode = 'anthropic' }
if (-not $Model) { $Model = $cfg.MODEL }
if (-not $OllamaHost) { $OllamaHost = $cfg.HOST }
if ($Ctx -le 0) { $Ctx = [int]$cfg.CTX }
$ClaudeArgs = @($ClaudeArgs | Where-Object { $_ -ne '--' })

function Get-NormalizedHost([string]$h) {
  if (-not $h) { $h = 'http://localhost:11434' }
  if ($h -notmatch '://') { $h = "http://$h" }
  $u = [Uri]$h
  $hostName = if ($u.Host -eq '0.0.0.0') { 'localhost' } else { $u.Host }
  $port = if ($h -match '://[^/]+:\d+') { $u.Port } else { 11434 }
  return "$($u.Scheme)://${hostName}:$port"
}
$OllamaHost = Get-NormalizedHost $OllamaHost

function Test-Server {
  try { Invoke-RestMethod -Uri "$OllamaHost/api/version" -TimeoutSec 3 | Out-Null; $true } catch { $false }
}
function Get-LocalModels {
  try { (Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 5).models | ForEach-Object { $_.name } } catch { @() }
}
function Test-Model([string]$m) {
  $full = if ($m -match ':') { $m } else { "${m}:latest" }
  $names = @(Get-LocalModels)
  return ($names -contains $m -or $names -contains $full)
}
function Start-Server {
  if (-not (Have 'ollama')) { Fail 'Ollama is not installed. Run install\install.ps1 or see https://ollama.com/download' }
  if ($OllamaHost -notmatch '://(localhost|127\.0\.0\.1)(:|$)') { Fail "Ollama at $OllamaHost is not reachable and is not on this machine" }
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  Info "Starting Ollama (context length $Ctx), log: $LogDir\serve.log"
  $env:OLLAMA_CONTEXT_LENGTH = "$Ctx"
  Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden `
    -RedirectStandardError (Join-Path $LogDir 'serve.log') -RedirectStandardOutput (Join-Path $LogDir 'serve.out.log')
  for ($i = 0; $i -lt 40; $i++) { if (Test-Server) { return }; Start-Sleep -Milliseconds 500 }
  Fail "Ollama did not start; see $LogDir\serve.log"
}
function Select-Model {
  $models = @(Get-LocalModels)
  if ($models.Count -eq 0) { Fail "no models found on $OllamaHost. Pass one with -Model (it will be pulled)" }
  if ($models.Count -eq 1) { return $models[0] }
  for ($i = 0; $i -lt $models.Count; $i++) { Write-Host ("{0}) {1}" -f ($i + 1), $models[$i]) }
  $n = [int](Read-Host 'model number')
  if ($n -lt 1 -or $n -gt $models.Count) { Fail 'no model chosen' }
  return $models[$n - 1]
}
function Test-SettingsOverride {
  $files = @((Join-Path $env:USERPROFILE '.claude\settings.json'), '.claude\settings.json', '.claude\settings.local.json')
  foreach ($f in $files) {
    if ((Test-Path $f) -and (Select-String -Path $f -Pattern '"ANTHROPIC_(BASE_URL|AUTH_TOKEN|API_KEY)"' -Quiet)) {
      Write-Warning "$f sets ANTHROPIC_* variables, which override this launcher"
    }
  }
}

switch ($Command) {
  'config' {
    "config file: $ConfigFile$(if (-not (Test-Path $ConfigFile)) { ' (not present)' })"
    "MODE=$Mode"; "MODEL=$Model"; "HOST=$OllamaHost"; "CTX=$Ctx"
    exit 0
  }
  'models' {
    if (-not (Test-Server)) { Fail "Ollama is not running at $OllamaHost" }
    Get-LocalModels
    exit 0
  }
  'doctor' {
    $ok = $true
    if (Have 'claude') { "  OK   Claude Code: $(claude --version | Select-Object -First 1)" } else { "  FAIL Claude Code not found"; $ok = $false }
    if ($Mode -eq 'cloud') {
      if ($env:OLLAMA_API_KEY) { '  OK   OLLAMA_API_KEY is set' } else { '  FAIL OLLAMA_API_KEY is not set'; $ok = $false }
    } elseif ($Mode -eq 'local') {
      if (Have 'ollama') { "  OK   Ollama CLI: $(ollama --version | Select-Object -Last 1)" } else { '  WARN Ollama CLI not found' }
      if (Test-Server) {
        "  OK   Ollama server at $OllamaHost, version $((Invoke-RestMethod "$OllamaHost/api/version").version)"
        $n = @(Get-LocalModels).Count
        if ($n -gt 0) { "  OK   $n model(s) available" } else { '  WARN no models pulled yet' }
      } else { "  WARN Ollama server not running at $OllamaHost (it is started on launch)" }
    }
    Test-SettingsOverride
    if ($ok) { 'All required checks passed.'; exit 0 } else { 'Some checks failed.'; exit 1 }
  }
}

# launch
$envVars = [ordered]@{}
switch ($Mode) {
  'local' {
    if (-not (Test-Server)) { if ($DryRun) { Write-Warning "Ollama is not running at $OllamaHost" } else { Start-Server } }
    if (-not $Model) { if ($DryRun) { $Model = '<choose>' } else { $Model = Select-Model } }
    if (-not $DryRun -and $Model -notmatch '(:|-)cloud$' -and -not (Test-Model $Model)) {
      if ($NoPull) { Fail "model '$Model' is not available on $OllamaHost" }
      Info "Pulling $Model"
      $env:OLLAMA_HOST = ($OllamaHost -replace '^https?://', '')
      ollama pull $Model
      if ($LASTEXITCODE -ne 0) { Fail "could not pull $Model" }
    }
    $envVars.ANTHROPIC_BASE_URL = $OllamaHost
    $envVars.ANTHROPIC_AUTH_TOKEN = 'ollama'
    $envVars.ANTHROPIC_API_KEY = ''
  }
  'cloud' {
    if (-not $env:OLLAMA_API_KEY) { Fail 'cloud mode needs OLLAMA_API_KEY (create one at https://ollama.com/settings/keys)' }
    if (-not $Model) { Fail 'cloud mode needs -Model (see https://ollama.com/search?c=cloud)' }
    $Model = $Model -replace ':cloud$', ''
    $envVars.ANTHROPIC_BASE_URL = 'https://ollama.com'
    $envVars.ANTHROPIC_AUTH_TOKEN = $env:OLLAMA_API_KEY
    $envVars.ANTHROPIC_API_KEY = ''
  }
  'anthropic' { }
  default { Fail "unknown mode '$Mode' (use local, cloud or anthropic)" }
}

$argList = @()
if ($Model) { $argList += @('--model', $Model) }
$argList += $ClaudeArgs

if ($DryRun) {
  foreach ($k in $envVars.Keys) {
    $v = if ($k -eq 'ANTHROPIC_AUTH_TOKEN' -and $Mode -eq 'cloud') { '<OLLAMA_API_KEY>' } else { $envVars[$k] }
    "`$env:$k = '$v'"
  }
  "claude $($argList -join ' ')"
  exit 0
}

if (-not (Have 'claude')) { Fail "Claude Code is not installed. Run install\install.ps1 or: irm https://claude.ai/install.ps1 | iex" }
Test-SettingsOverride
foreach ($k in $envVars.Keys) { Set-Item -Path "env:$k" -Value $envVars[$k] }
# PowerShell drops empty env vars; Claude Code treats a missing ANTHROPIC_API_KEY the same as empty.
Info "Launching Claude Code (mode: $Mode$(if ($Model) { ", model: $Model" }))"
& claude @argList
exit $LASTEXITCODE
