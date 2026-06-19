<#
=============================================================================
 PrecisionIT - precisionit-mail (SMTP2GO) MCP connector installer (Windows)
=============================================================================
 Installs the precisionit-mail MCP server and wires BOTH Claude Code
 (~/.claude.json) and Claude Desktop (%APPDATA%\Claude\claude_desktop_config.json)
 with machine-resolved absolute paths.

 Key sources:
   keyvault (default) - SMTP2GO key pulled at runtime from Azure Key Vault via the
                        per-user launcher under the tech's `az login`; never in config.
   static             - SMTP2GO key written into the config env (plaintext).

 The connector sends as MAIL_SENDER (the installing tech's address). That address
 MUST be on a domain verified in the PrecisionIT SMTP2GO account.

 Config files are written UTF-8 *without* a BOM, so the Claude Desktop JSON parser
 won't silently refuse to load them (the classic Windows BOM trap).

 Safe to re-run: git pull + rewrites only the "precisionit-mail" entry.

 Run with:
   powershell -ExecutionPolicy Bypass -File .\install.ps1
=============================================================================
#>
[CmdletBinding()]
param(
  [string]$RepoUrl     = $(if ($env:PRECISIONIT_MAIL_REPO_URL) { $env:PRECISIONIT_MAIL_REPO_URL } else { "https://github.com/dspray/precisionit-mail.git" }),
  [string]$InstallRoot = $(if ($env:PRECISIONIT_MAIL_HOME)     { $env:PRECISIONIT_MAIL_HOME }     else { Join-Path $env:USERPROFILE "Claude\mcp" }),
  [string]$VaultRwUrl  = $(if ($env:KV_VAULT_RW_URL)           { $env:KV_VAULT_RW_URL }           else { "https://PrecisionIT-MCP-RW.vault.azure.net/" }),
  [string]$VaultRoUrl  = $(if ($env:KV_VAULT_RO_URL)           { $env:KV_VAULT_RO_URL }           else { "https://PrecisionIT-MCP-RO.vault.azure.net/" }),
  [string]$MailSender  = $env:MAIL_SENDER,
  [string]$KeySource   = $(if ($env:MAIL_KEY_SOURCE)           { $env:MAIL_KEY_SOURCE }           else { "keyvault" }),
  [string]$Smtp2goKey  = $env:SMTP2GO_API_KEY,
  # >>> CONFIRM this matches the real vault secret name holding the SMTP2GO key <<<
  [string]$SecretSpec  = $(if ($env:MAIL_SECRET_SPEC)          { $env:MAIL_SECRET_SPEC }          else { "Smtp2goApiKey:SMTP2GO_API_KEY" })
)
$ErrorActionPreference = "Stop"

function Say  ($m) { Write-Host "[mail-install] $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "[mail-install] WARN: $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "[mail-install] FATAL: $m" -ForegroundColor Red; exit 1 }

# UTF-8 *without* BOM — the only safe encoding for Claude Desktop's config parser.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- 0. Validate ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($MailSender)) { Die "MAIL_SENDER is required (a verified SMTP2GO sender). Set `$env:MAIL_SENDER='you@myprecisionit.com' and re-run." }
if ($KeySource -eq "static") {
  if ([string]::IsNullOrWhiteSpace($Smtp2goKey)) { Die "MAIL_KEY_SOURCE=static requires SMTP2GO_API_KEY to be set." }
} elseif ($KeySource -ne "keyvault") {
  Die "MAIL_KEY_SOURCE must be 'keyvault' or 'static', got '$KeySource'."
}

# ---- 1. Prerequisites -------------------------------------------------------
Say "Checking prerequisites..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git not found. Install Git for Windows (winget install Git.Git), then re-run." }

$nodeCmd = (Get-Command node -ErrorAction SilentlyContinue)
if (-not $nodeCmd) { Die "node not found on PATH. Install Node 18+ (winget install OpenJS.NodeJS.LTS), then re-run." }
$NodeBin = $nodeCmd.Source
$NodeMajor = [int](& node -p "process.versions.node.split('.')[0]")
if ($NodeMajor -lt 18) { Die "Node $NodeMajor found; precisionit-mail requires Node >=18." }
Say "node: $NodeBin (v$(& node -p 'process.versions.node'))"

if ($KeySource -eq "keyvault") {
  $azCmd = (Get-Command az -ErrorAction SilentlyContinue)
  if ($azCmd) {
    Say "az: $($azCmd.Source)"
    try { az account show 1>$null 2>$null; if ($LASTEXITCODE -eq 0) { Say "az session: active" } else { Warn "az installed but NOT logged in. Run 'az login' before using the connector." } }
    catch { Warn "az installed but NOT logged in. Run 'az login' before using the connector." }
  } else {
    Warn "Azure CLI (az) not found. Install it (winget install Microsoft.AzureCLI) and run 'az login' before using the connector."
  }
}

# ---- 2. Clone or update -----------------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
$SrcDir = Join-Path $InstallRoot "precisionit-mail"
if (Test-Path (Join-Path $SrcDir ".git")) {
  Say "Updating existing checkout at $SrcDir"
  git -C $SrcDir pull --ff-only
} else {
  Say "Cloning $RepoUrl -> $SrcDir"
  git clone --depth 1 $RepoUrl $SrcDir
}

$ServerJs   = Join-Path $SrcDir "server.js"
$LauncherJs = Join-Path $SrcDir "launcher\mcp-keyvault-launch.js"
if (-not (Test-Path $ServerJs)) { Die "server not found at $ServerJs - repo layout unexpected." }

# ---- 3. Dependencies --------------------------------------------------------
Say "Installing server dependencies (npm ci)..."
Push-Location $SrcDir; npm ci --omit=dev --no-audit --no-fund; Pop-Location
if ($KeySource -eq "keyvault") {
  if (-not (Test-Path $LauncherJs)) { Die "launcher not found at $LauncherJs - add the launcher\ folder to the repo (copy it verbatim from claude-meraki-mcp)." }
  Say "Installing launcher dependencies (npm install)..."
  Push-Location (Join-Path $SrcDir "launcher"); npm install --omit=dev --no-audit --no-fund; Pop-Location
}

# ---- 4. Build the entry -----------------------------------------------------
if ($KeySource -eq "keyvault") {
  $entry = [ordered]@{
    command = $NodeBin
    args    = @($LauncherJs, "--secret", $SecretSpec, "--", $NodeBin, $ServerJs)
    env     = [ordered]@{
      KV_VAULT_RW_URL = $VaultRwUrl
      KV_VAULT_RO_URL = $VaultRoUrl
      MAIL_SENDER     = $MailSender
    }
  }
} else {
  $entry = [ordered]@{
    command = $NodeBin
    args    = @($ServerJs)
    env     = [ordered]@{
      SMTP2GO_API_KEY = $Smtp2goKey
      MAIL_SENDER     = $MailSender
    }
  }
}

# ---- 5. Read-modify-write a config (preserves other connectors, BOM-free) --
function Wire-Config([string]$Cfg, [string]$Label) {
  $dir = Split-Path -Parent $Cfg
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (-not (Test-Path $Cfg)) { [System.IO.File]::WriteAllText($Cfg, "{}", $Utf8NoBom) }
  Copy-Item $Cfg "$Cfg.bak.$(Get-Date -Format yyyyMMddHHmmss)"
  # ReadAllText auto-discards any pre-existing BOM left by another tool.
  $raw = [System.IO.File]::ReadAllText($Cfg)
  if ([string]::IsNullOrWhiteSpace($raw)) { $raw = "{}" }
  $json = $raw | ConvertFrom-Json
  if (-not $json.mcpServers) { $json | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force }
  $json.mcpServers | Add-Member -NotePropertyName "precisionit-mail" -NotePropertyValue ([pscustomobject]$entry) -Force
  [System.IO.File]::WriteAllText($Cfg, ($json | ConvertTo-Json -Depth 12), $Utf8NoBom)
  Say "Wired '$Label' -> $Cfg (backup saved)"
}

Wire-Config (Join-Path $env:USERPROFILE ".claude.json") "Claude Code"
Wire-Config (Join-Path $env:APPDATA "Claude\claude_desktop_config.json") "Claude Desktop (Windows)"

Say "Install complete (key source: $KeySource, sender: $MailSender)."
if ($KeySource -eq "keyvault") {
  Say "NEXT: run 'az login' if you haven't, then fully restart Claude Desktop / reload Claude Code."
} else {
  Say "NEXT: fully restart Claude Desktop / reload Claude Code."
}
