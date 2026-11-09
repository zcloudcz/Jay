# Jay: create, update or remove a bot on this Windows computer with ONE command.
#
#   & ([scriptblock]::Create((irm https://jay.zcloud.cz/bots/new-bot.ps1))) -Name 'My bot' -Owner CT-XXXX-XXXX -Provider anthropic
#
# Spec: docs/superpowers/specs/2026-11-09-bot-factory.md (B6). The Jay app
# (Settings > Bots > New bot) prints this command with your handle filled in.
# Windows PowerShell 5.1 and PowerShell 7 both work; no admin rights needed.
#
# What it does: downloads the bot bundle to %USERPROFILE%\.jay-bots\<name>\,
# generates the bot's store key (never printed), asks for the provider API
# key with a hidden prompt (or reads it from the environment; never from an
# argument, so it stays out of the history), writes a settings file only you
# can read, registers a Scheduled Task that starts the bot when you log on,
# starts it and waits until the bot is connected. The bot then writes to you
# in Jay. Rerun with the same -Name to update: the identity is kept.
# -Remove stops and deletes it.
#
# The bot's private keys are created on THIS computer and never leave it.
# The bot runs only while this computer runs and you are logged on.
[CmdletBinding()]
param(
  [string]$Name,
  [string]$Owner,
  [ValidateSet('anthropic', 'openai', 'claude-cli', 'codex-cli', 'hermes')]
  [string]$Provider = 'anthropic',
  [string]$Api = 'https://calltype-beta-zahy.azurewebsites.net',
  [string]$Model,
  [string]$Prompt,
  [string]$BaseUrl,
  [string]$HermesUrl,
  # members | owners: who besides you the bot answers in a group you are in
  # (default: members for API keys, owners for claude-cli/codex-cli).
  [ValidateSet('', 'members', 'owners')]
  [string]$GroupReplies = '',
  [switch]$Remove,
  [switch]$Yes,
  [switch]$DryRun,
  # Test hook for the dry-run matrix.
  [string]$Arch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Fail([string]$message) {
  Write-Host "jay-new-bot: $message" -ForegroundColor Red
  throw "jay-new-bot: $message"
}
function Note([string]$message) { if ($DryRun) { Write-Host "[dry-run] $message" } }

$bundleBase = if ($env:JAY_BOT_BUNDLE_BASE) { $env:JAY_BOT_BUNDLE_BASE } else { 'https://github.com/zcloudcz/Jay/releases/download/llm-bridge-latest' }
$botsDir = if ($env:JAY_BOTS_DIR) { $env:JAY_BOTS_DIR } else { Join-Path $env:USERPROFILE '.jay-bots' }

# --- validation ---------------------------------------------------------------
if (-not $Name) { Fail '-Name is required' }
if ($Name.Length -gt 40) { Fail '-Name is longer than 40 characters' }
if ($Name -match '[\x00-\x1f]') { Fail '-Name must not contain control characters' }
# Folder and task name: lower-case letters, digits and dashes only.
# Accented letters become their base letter first ("muj-bot", not "m-j-bot"),
# like the bash script.
$ascii = ($Name.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '')
$slug = ($ascii.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if ($slug.Length -gt 32) { $slug = $slug.Substring(0, 32).TrimEnd('-') }
if (-not $slug) { Fail '-Name must contain at least one letter or digit (a-z, 0-9)' }
$taskName = "Jay bot $slug"
$botDir = Join-Path $botsDir $slug
$settingsFile = Join-Path $botDir 'bot.env.json'
$logFile = Join-Path $botDir 'bot.log'
$errFile = Join-Path $botDir 'bot.err.log'
$bridge = if ($Provider -eq 'hermes') { 'hermes_bridge' } else { 'llm_bridge' }

$owners = @()
if (-not $Remove) {
  if (-not $Owner) { Fail '-Owner is required (your handle: Jay > Settings > Identity)' }
  $owners = @($Owner.ToUpperInvariant() -replace '\s', '' -split ',' | Where-Object { $_ })
  if ($owners.Count -eq 0) { Fail '-Owner is empty' }
  foreach ($h in $owners) {
    if ($h -notmatch '^CT-[A-Z0-9]{4}-[A-Z0-9]{4}$') { Fail "-Owner: '$h' is not a Jay handle (CT-XXXX-XXXX)" }
  }
  if ($Api -notmatch '^(https://|http://localhost|http://127\.0\.0\.1)') { Fail '-Api must be an https:// URL' }
  $Api = $Api.TrimEnd('/')
  if ($BaseUrl) {
    if ($Provider -ne 'openai') { Fail '-BaseUrl is only for -Provider openai' }
    if ($BaseUrl -notmatch '^https?://') { Fail '-BaseUrl must be an http(s) URL' }
    $BaseUrl = $BaseUrl.TrimEnd('/')
  }
  if ($HermesUrl -and $Provider -ne 'hermes') { Fail '-HermesUrl is only for -Provider hermes' }
  if ($GroupReplies -and $Provider -eq 'hermes') { Fail '-GroupReplies is not for -Provider hermes (Hermes answers owners only)' }
}

$cpu = if ($Arch) { $Arch } else { $env:PROCESSOR_ARCHITECTURE }
# Windows on ARM runs x64 programs through its built-in emulation.
if ($cpu -notin @('AMD64', 'x64', 'ARM64', 'arm64')) { Fail "unsupported CPU '$cpu': use Docker or a 64-bit Windows" }

# --- helpers -------------------------------------------------------------------
function Get-OldSetting {
  if (Test-Path -LiteralPath $settingsFile) {
    return Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json
  }
  return $null
}
function Get-Old($settings, [string]$key) {
  if ($null -eq $settings) { return '' }
  $p = $settings.PSObject.Properties[$key]
  if ($null -eq $p) { return '' }
  return [string]$p.Value
}

function Stop-Bot {
  if ($DryRun) {
    Note "would stop the Scheduled Task '$taskName' and the bot process"
    return
  }
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue }
  # The task runs a PowerShell loop that starts the exe; stop the exe too.
  $appDir = Join-Path $botDir 'app'
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}

# --- remove --------------------------------------------------------------------
if ($Remove) {
  Write-Host "Removing bot '$Name' ($taskName)."
  Stop-Bot
  if ($DryRun) {
    Note "would unregister the Scheduled Task '$taskName'"
  } else {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }
  $delete = $false
  if ($Yes) {
    $delete = $true
  } elseif ($DryRun) {
    Note "would ask before deleting the identity in $botDir"
  } else {
    $answer = Read-Host "Also delete its identity and chat history ($botDir)? The handle stops working for good. [y/N]"
    $delete = $answer -match '^(y|yes|a|ano)$'
  }
  if ($delete) {
    if ($DryRun) { Note "would delete $botDir" } else { Remove-Item -Recurse -Force -LiteralPath $botDir -ErrorAction SilentlyContinue }
    Write-Host "Deleted. The bot's identity is gone."
  } else {
    Write-Host "Task removed. Identity kept in $botDir."
    Write-Host "Run the setup command again with -Name '$Name' to bring the same bot back."
  }
  return
}

# --- secrets ---------------------------------------------------------------------
$old = Get-OldSetting
$storeKey = Get-Old $old 'BOT_STORE_KEY'
if ($storeKey) {
  Note 'keeps the existing BOT_STORE_KEY (same identity)'
} elseif ($DryRun) {
  Note 'would generate BOT_STORE_KEY (32 random bytes, never printed)'
} else {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $rng.Dispose()
  $storeKey = [Convert]::ToBase64String($bytes)
}

$keyVar = switch ($Provider) {
  'anthropic' { 'ANTHROPIC_API_KEY' }
  'openai' { 'OPENAI_API_KEY' }
  'hermes' { 'HERMES_API_KEY' }
  default { '' }
}
$apiKey = ''
if ($keyVar) {
  $apiKey = [Environment]::GetEnvironmentVariable($keyVar)
  if (-not $apiKey) { $apiKey = Get-Old $old $keyVar }
  if (-not $apiKey) {
    # A local OpenAI-compatible server (Ollama, LM Studio) needs no key.
    $optional = ($Provider -eq 'openai' -and $BaseUrl)
    if ($DryRun) {
      Note "would ask for $keyVar with a hidden prompt"
    } else {
      $hint = switch ($Provider) {
        'anthropic' { ' (https://platform.claude.com > API keys)' }
        'openai' { if ($optional) { ' (empty if the server needs none)' } else { ' (https://platform.openai.com/api-keys)' } }
        'hermes' { " (Hermes' API_SERVER_KEY)" }
      }
      $secure = Read-Host -AsSecureString "$keyVar$hint"
      $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
      try { $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
      finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
      if (-not $apiKey -and -not $optional) { Fail "$keyVar is needed" }
    }
  }
}

# Keep earlier optional settings on a rerun unless given again.
if (-not $PSBoundParameters.ContainsKey('Model')) { $Model = Get-Old $old 'LLM_MODEL' }
if (-not $PSBoundParameters.ContainsKey('Prompt')) { $Prompt = Get-Old $old 'LLM_SYSTEM_PROMPT' }
if (-not $PSBoundParameters.ContainsKey('BaseUrl')) { $BaseUrl = Get-Old $old 'OPENAI_BASE_URL' }
if (-not $PSBoundParameters.ContainsKey('GroupReplies')) { $GroupReplies = Get-Old $old 'GROUP_REPLIES' }
if ($Provider -eq 'hermes') {
  if (-not $HermesUrl) { $HermesUrl = Get-Old $old 'HERMES_URL' }
  if (-not $HermesUrl) { $HermesUrl = 'http://127.0.0.1:8642' }
}
if ($Provider -eq 'openai' -and $BaseUrl -and -not $Model) {
  Fail '-Model is required with -BaseUrl (the endpoint decides which models exist)'
}

# --- CLI providers: the owner's own, signed-in CLI ----------------------------------
$cliVar = ''
$cliPath = ''
$servicePrefix = ''
if ($Provider -eq 'claude-cli' -or $Provider -eq 'codex-cli') {
  $cli = if ($Provider -eq 'claude-cli') { 'claude' } else { 'codex' }
  $cliVar = if ($cli -eq 'claude') { 'CLAUDE_BIN' } else { 'CODEX_BIN' }
  # -CommandType Application: the .exe or .cmd, not a .ps1 shim the bot
  # could not start.
  $cmd = Get-Command $cli -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $override = [Environment]::GetEnvironmentVariable($cliVar)
  if ($override) {
    # An explicit choice, e.g. a second install.
    if (-not (Test-Path -LiteralPath $override -PathType Leaf)) { Fail "$cliVar=$override is not a file" }
    $cliPath = $override
  }
  elseif ($cmd) { $cliPath = $cmd.Source }
  elseif ($DryRun) { $cliPath = "C:\Program Files\$cli\$cli.exe" }
  else {
    if ($cli -eq 'claude') {
      Fail "Claude Code (claude) is not installed. Install it (https://code.claude.com/docs/en/setup), run 'claude' once and sign in with your Claude account, then run this command again."
    }
    Fail "Codex CLI (codex) is not installed. Install it (https://developers.openai.com/codex/cli), run 'codex login', then run this command again."
  }
  # npm installs claude/codex as a .cmd shim that runs node.exe from PATH
  # (a native installer ships an .exe). Find that interpreter now, put its
  # folder first on the bot's PATH in run.ps1, and start the CLI once with
  # that PATH before anything is installed: a bot that cannot start its CLI
  # only answers every message with an error.
  $sep = [IO.Path]::PathSeparator
  $interp = ''
  $prefixDirs = @()
  if (Test-Path -LiteralPath $cliPath -PathType Leaf) {
    $isScript = $cliPath -match '\.(cmd|bat|ps1)$'
    if (-not $isScript) {
      $fs = [IO.File]::OpenRead($cliPath)
      try { $isScript = ($fs.ReadByte() -eq 35) -and ($fs.ReadByte() -eq 33) } finally { $fs.Dispose() } # '#!'
    }
    if ($isScript) {
      $head = (Get-Content -LiteralPath $cliPath -TotalCount 40) -join "`n"
      if ($head -match '^#!\S*env\s+(?:-S\s*)?([^\s-]\S*)') { $interp = $Matches[1] }
      elseif ($head -match '(?i)\bnode(\.exe)?\b') { $interp = 'node' }
    }
  }
  $cliDir = Split-Path -Parent $cliPath
  if ($interp) {
    $found = Get-Command $interp -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $prefixDirs += Split-Path -Parent $found.Source }
    elseif (-not (Test-Path -LiteralPath (Join-Path $cliDir "$interp.exe"))) {
      Fail "$cli at $cliPath runs '$interp', but '$interp' is not on your PATH. Install it (node: https://nodejs.org) so that '$interp' works in this terminal, then run this command again."
    }
  }
  $prefixDirs += $cliDir
  $servicePrefix = ($prefixDirs | Select-Object -Unique) -join $sep
  # The task inherits the user's PATH (machine + user); run.ps1 puts the
  # folders above in front of it.
  $basePath = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }
  if (-not $basePath) { $basePath = @('/usr/local/bin', '/usr/bin', '/bin') } # pwsh on Linux (tests)
  $servicePath = (@($servicePrefix) + $basePath) -join $sep
  if ($DryRun) {
    $interpNote = if ($interp) { " (includes the folder of $interp, which $cli needs)" } else { '' }
    Note "service PATH=$servicePath$interpNote"
    Note "would check that $cli starts the way the bot starts it: $cliPath --version with that PATH"
  } else {
    $oldPath = $env:PATH
    $checkCode = 0
    $checkOut = ''
    try {
      $ErrorActionPreference = 'Continue' # a CLI may write to stderr and still succeed
      $env:PATH = $servicePath
      $checkOut = (& $cliPath --version 2>&1 | Out-String).Trim()
      $checkCode = $LASTEXITCODE
    } catch {
      $checkOut = $_.Exception.Message
      $checkCode = -1
    } finally {
      $env:PATH = $oldPath
      $ErrorActionPreference = 'Stop'
    }
    if ($checkCode -ne 0) {
      if ($interp) {
        Fail "$interp (or something it needs) is not found in the bot's PATH ($servicePath): '$cli --version' failed with exit $($checkCode): $checkOut. Install $interp in a standard place, or make sure '$interp' works from that PATH, then run this command again."
      }
      Fail "$cli at $cliPath does not start with the bot's PATH ($servicePath): '$cli --version' failed with exit $($checkCode): $checkOut"
    }
    Write-Host "Checked: $cli starts with the bot's PATH."
  }
  if (-not $DryRun) {
    $statusArgs = if ($cli -eq 'claude') { @('auth', 'status') } else { @('login', 'status') }
    & $cliPath @statusArgs *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "Warning: '$cli $($statusArgs -join ' ')' says you are not signed in. Sign in first, or the bot will answer with an error." -ForegroundColor Yellow
    }
  }
  Write-Host "Using your own $cli at $cliPath (personal use only; Jay never sees your login)."
  # Spec 2026-11-09-bot-access A7: Windows has no sandbox for the CLI in
  # this setup, and group members could make the bot run it.
  if ($GroupReplies -eq 'members') {
    Write-Host "WARNING: group members can make this bot run your $cli, and there is no sandbox on Windows." -ForegroundColor Yellow
    Write-Host '  Run the bot under a separate Windows user, or use -GroupReplies owners. See infra/bots/README.md.' -ForegroundColor Yellow
  }
}

Write-Host "Setting up bot '$Name' for $($owners -join ',') ($Provider, Scheduled Task) in $botDir"

# --- bundle -----------------------------------------------------------------------
$asset = "jay-$($bridge -replace '_', '-')-windows-x64.zip"
$url = "$bundleBase/$asset"
if ($DryRun) {
  Note "would download $url and check it against $bundleBase/SHA256SUMS"
  Stop-Bot
  Note "would unpack it to $botDir\app (replacing an older version)"
} else {
  # Windows PowerShell 5.1 defaults to TLS 1.0, which GitHub refuses.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  New-Item -ItemType Directory -Force -Path $botDir | Out-Null
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("jay-bot-" + [Guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    Write-Host "Downloading $asset ..."
    $zip = Join-Path $tmp $asset
    $sums = Join-Path $tmp 'SHA256SUMS'
    $ProgressPreference = 'SilentlyContinue' # 5.1's progress bar makes downloads very slow
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    Invoke-WebRequest -UseBasicParsing -Uri "$bundleBase/SHA256SUMS" -OutFile $sums
    $line = Get-Content -LiteralPath $sums | Where-Object { $_ -match "\s\*?$([regex]::Escape($asset))$" } | Select-Object -First 1
    if (-not $line) { Fail "$asset is not listed in SHA256SUMS" }
    $want = ($line -split '\s+')[0].ToLowerInvariant()
    $have = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($want -ne $have) { Fail "checksum mismatch for $asset (download damaged?); nothing was changed" }
    $app = Join-Path $botDir 'app'
    $newApp = Join-Path $tmp 'app'
    Expand-Archive -LiteralPath $zip -DestinationPath $newApp -Force
    # Only now, with a verified bundle, stop a running bot (an update keeps
    # the old bot running when the download fails).
    Stop-Bot
    if (Test-Path -LiteralPath $app) { Remove-Item -Recurse -Force -LiteralPath $app }
    Move-Item -LiteralPath $newApp -Destination $app
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  }
}

# --- settings + start wrapper -----------------------------------------------------------
$settings = [ordered]@{
  CALLTYPE_API_URL = $Api
  BOT_STORE_PATH   = (Join-Path $botDir 'data\bot.store')
  BOT_STORE_KEY    = $storeKey
  ALLOWED_HANDLES  = ($owners -join ',')
  BOT_DISPLAY_NAME = $Name
}
if ($Provider -eq 'hermes') {
  $settings.HERMES_URL = $HermesUrl
  $settings.HERMES_API_KEY = $apiKey
} else {
  $settings.LLM_PROVIDER = $Provider
  if ($Model) { $settings.LLM_MODEL = $Model }
  if ($Prompt) { $settings.LLM_SYSTEM_PROMPT = $Prompt }
  if ($keyVar -and $apiKey) { $settings[$keyVar] = $apiKey }
  if ($BaseUrl) { $settings.OPENAI_BASE_URL = $BaseUrl }
  if ($GroupReplies) { $settings.GROUP_REPLIES = $GroupReplies }
  if ($cliVar) { $settings[$cliVar] = $cliPath }
}

$runFile = Join-Path $botDir 'run.ps1'
$exeName = "$bridge.exe"
if ($DryRun) {
  Note "would write $settingsFile (readable only by you): settings and secrets, values hidden"
  Note "would write $runFile (loads the settings, starts app\bin\$exeName, restarts it unless the settings are wrong$(if ($servicePrefix) { ", PATH starts with $servicePrefix" }))"
} else {
  New-Item -ItemType Directory -Force -Path (Join-Path $botDir 'data') | Out-Null
  $settings | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
  # Only the current user may read the secrets (no inherited access).
  & icacls.exe $settingsFile /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
  $quotedDir = $botDir -replace "'", "''"
  # The CLI providers start a CLI (and node for an npm .cmd shim): put the
  # folders checked above in front of the task's PATH.
  $pathLine = if ($servicePrefix) { "`$env:PATH = '$($servicePrefix -replace "'", "''")' + [IO.Path]::PathSeparator + `$env:PATH" } else { '' }
  @"
# Generated by jay-new-bot.ps1: starts the bot '$slug' with its settings.
`$dir = '$quotedDir'
$pathLine
`$settings = Get-Content -Raw -LiteralPath (Join-Path `$dir 'bot.env.json') | ConvertFrom-Json
foreach (`$p in `$settings.PSObject.Properties) { [Environment]::SetEnvironmentVariable(`$p.Name, [string]`$p.Value, 'Process') }
`$exe = Join-Path `$dir 'app\bin\$exeName'
while (`$true) {
  # stdout/stderr of the latest run (a file per stream, overwritten on restart).
  `$p = Start-Process -FilePath `$exe -NoNewWindow -PassThru -Wait ``
    -RedirectStandardOutput (Join-Path `$dir 'bot.log') -RedirectStandardError (Join-Path `$dir 'bot.err.log')
  # 78 = configuration error: restarting cannot fix it.
  if (`$p.ExitCode -eq 78) { break }
  Start-Sleep -Seconds 10
}
"@ | Set-Content -LiteralPath $runFile -Encoding UTF8
}

# --- Scheduled Task ------------------------------------------------------------------------
$user = "$env:USERDOMAIN\$env:USERNAME"
if ($DryRun) {
  Note "would register the Scheduled Task '$taskName' (at logon of $user, no time limit) and start it"
  Note "would wait for 'Connected.' in $logFile and print the handle and invite"
  return
}
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runFile`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $taskSettings `
  -Principal $principal -Description "Jay bot '$Name' (jay-new-bot.ps1)" -Force | Out-Null
foreach ($f in @($logFile, $errFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -Force -LiteralPath $f } }
Start-ScheduledTask -TaskName $taskName

Write-Host 'Starting ...'
$out = ''
$ok = $false
for ($i = 0; $i -lt 90; $i++) {
  Start-Sleep -Seconds 1
  $out = if (Test-Path -LiteralPath $logFile) { Get-Content -Raw -LiteralPath $logFile } else { '' }
  if ($out -match 'Connected\.') { $ok = $true; break }
  $err = if (Test-Path -LiteralPath $errFile) { Get-Content -Raw -LiteralPath $errFile } else { '' }
  if ($err -and $err.Trim()) { Write-Host $err -ForegroundColor Red; break }
}
if (-not $ok) {
  Stop-Bot
  Fail "the bot did not start (log: $logFile, $errFile)"
}
$handle = [regex]::Match($out, 'CT-[A-Z0-9]{4}-[A-Z0-9]{4}').Value
$invite = [regex]::Match($out, 'ct://\S+').Value
Write-Host ''
Write-Host "Bot '$Name' is running."
if ($handle) { Write-Host "  Handle: $handle" }
if ($invite) { Write-Host "  Invite: $invite" }
if ($Provider -eq 'hermes') {
  Write-Host 'Open Jay and add the bot by its handle (or paste the invite).'
} else {
  Write-Host 'Check Jay: the bot just wrote to you (first start only). Reply to it to start chatting.'
}
Write-Host 'Update: run the same command again. Remove: add -Remove.'
