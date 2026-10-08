<#
.SYNOPSIS
  Owner tasks that unblock the Jay beta (things only Martin can do).
  Interactive menu; every step is idempotent and asks before writing.

.DESCRIPTION
  Run from the repo root in PowerShell 7:

      pwsh docs/ops/owner-tasks.ps1

  Steps:
    1  Audit DB migrations on beta   (dotnet ef + psql via Docker)
    2  Download Android/Windows artifacts of the last green deploy
    3  Apple TestFlight secrets (ASC key, Team ID) into GitHub env
    4  Firebase config files + server service-account secret
    5  Print archiver (Linux server) instructions

  Secrets are read with Read-Host -AsSecureString or from files; nothing is
  echoed or stored in shell history. psql runs in a throw-away Docker container
  because it is not installed locally.
#>
#Requires -Version 7
$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path "$PSScriptRoot/../..")

$Repo       = 'zcloudcz/Jay'
$Rg         = 'rg-calltype-beta'
$WebApp     = 'calltype-beta-zahy'
$PgHost     = '187.127.83.154'; $PgPort = 5544; $PgDb = 'calltype_audit'; $PgOps = 'calltype_audit_ops'
$AuditProj  = 'src/server/CallType.Audit'
$ApiProj    = 'src/server/CallType.Api'
$Tmp        = Join-Path $env:TEMP 'jay-owner'
New-Item -ItemType Directory -Force $Tmp | Out-Null

function Confirm($msg) { (Read-Host "$msg [y/N]") -match '^[yY]' }
function Need($cmd) { if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "Missing tool: $cmd" } }
function Plain([securestring]$s) { [Net.NetworkCredential]::new('', $s).Password }

# psql through Docker; password travels as env var, never as an argument.
function Invoke-Psql([string]$Password, [string[]]$PsqlArgs, [string]$MountFile) {
    Need docker
    $vol = @(); if ($MountFile) { $vol = @('-v', "$((Resolve-Path $MountFile).Path):/in.sql:ro") }
    $env:PGPASSWORD = $Password
    try {
        docker run --rm -i -e PGPASSWORD @vol postgres:16 psql `
            "host=$PgHost port=$PgPort dbname=$PgDb user=$PgOps sslmode=require" @PsqlArgs
    } finally { Remove-Item Env:PGPASSWORD }
}

function Step-AuditMigrations {
    Need dotnet
    $sql = Join-Path $Tmp 'audit-migrations.sql'
    Write-Host "`n== Generating idempotent migration script → $sql"
    dotnet ef migrations script --idempotent --project $AuditProj --startup-project $ApiProj -o $sql | Out-Null
    $pw = Plain (Read-Host "Password for $PgOps@$PgDb" -AsSecureString)

    Write-Host "`n== Applied migrations on beta:"
    Invoke-Psql $pw @('-c', 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY 1;')
    Write-Host "`n== Migrations in repo:"
    Get-ChildItem "$AuditProj/Migrations" -Filter '*.cs' | Where-Object Name -notmatch 'Designer|Snapshot' | ForEach-Object { "  $($_.BaseName)" }

    if (Confirm "`nApply the script (idempotent, safe to re-run) and re-lock __EFMigrationsHistory?") {
        Invoke-Psql $pw @('-v', 'ON_ERROR_STOP=1', '-f', '/in.sql') -MountFile $sql
        Invoke-Psql $pw @('-c', 'REVOKE INSERT ON "__EFMigrationsHistory" FROM calltype_audit_app;')
        Write-Host "Done. Re-check:"
        Invoke-Psql $pw @('-c', 'SELECT "MigrationId" FROM "__EFMigrationsHistory" ORDER BY 1;')
    }
}

function Step-DownloadArtifacts {
    Need gh
    $run = gh run list -R $Repo -w deploy.yml -s success -L 1 --json databaseId,headSha,createdAt | ConvertFrom-Json | Select-Object -First 1
    if (-not $run) { throw 'No successful deploy run found.' }
    $dir = Join-Path $Tmp "artifacts-$($run.databaseId)"
    Write-Host "`n== Last green deploy: run $($run.databaseId), sha $($run.headSha), $($run.createdAt)"
    gh run download $run.databaseId -R $Repo -D $dir
    Write-Host "`nDownloaded to $dir"
    Get-ChildItem $dir -Recurse -Include *.apk, *.zip, *.msix, build-manifest.json | ForEach-Object { "  $($_.FullName)" }
    Write-Host "`nAndroid: connect phone with USB debugging, then:"
    Write-Host "  adb install -r <path-to>.apk"
    Write-Host "Windows: unzip, run calltype.exe."
    Write-Host "Record results in docs/acceptance/matrix.md (date UTC, device, OS, peer, network, outcome)."
}

function Step-AppleSecrets {
    Need gh
    Write-Host "`nOne-time in the browser first (see docs/acceptance/ios-testflight.md):"
    Write-Host "  developer.apple.com → Identifiers → App ID 'cz.zcloud.jay'"
    Write-Host "  appstoreconnect.apple.com → Apps → New App 'Jay', bundle cz.zcloud.jay, SKU jay-ios"
    Write-Host "  App Store Connect → Users and Access → Integrations → Team Keys → '+' role App Manager → download .p8"
    Write-Host "  developer.apple.com → Membership → Team ID"
    if (-not (Confirm "Done, continue with secrets?")) { return }

    $keyId  = Read-Host 'ASC Key ID (10 chars)'
    $issuer = Read-Host 'ASC Issuer ID (uuid)'
    $team   = Read-Host 'Apple Team ID (10 chars)'
    $p8     = Read-Host 'Path to AuthKey_XXXXXXXXXX.p8'
    if (-not (Test-Path $p8)) { throw "File not found: $p8" }

    $env:GH_TOKEN_UNUSED = $null
    $keyId  | gh secret set ASC_KEY_ID        -R $Repo --env apple-testflight
    $issuer | gh secret set ASC_ISSUER_ID     -R $Repo --env apple-testflight
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($p8)) | gh secret set ASC_KEY_P8_BASE64 -R $Repo --env apple-testflight
    gh variable set APPLE_TEAM_ID -R $Repo --env apple-testflight --body $team
    Write-Host "`nSecrets set. Move the .p8 into your password manager and delete it from disk."

    $sha = git rev-parse HEAD
    Write-Host "`nFirst TestFlight upload runs on a macOS runner → repo must be PUBLIC for the window (/gh-actions-public)."
    Write-Host "Command (full SHA of current HEAD):"
    Write-Host "  gh workflow run ios-testflight.yml -R $Repo -f commit_sha=$sha"
    Write-Host "Afterwards: App Store Connect → TestFlight → answer Export Compliance → add build to tester group."
}

function Step-Firebase {
    Need az
    Write-Host "`nOne-time in the browser first: console.firebase.google.com → new project 'Jay'."
    Write-Host "  Add Android app (package: see android/app/build.gradle applicationId) → download google-services.json"
    Write-Host "  Add iOS app (bundle cz.zcloud.jay)                                   → download GoogleService-Info.plist"
    Write-Host "  Project settings → Service accounts → Generate new private key       → download <sa>.json  (SERVER SECRET)"
    Write-Host "  Project settings → General → Web app → copy config object; Cloud Messaging → Web Push certificates → VAPID key"
    if (-not (Confirm "Files downloaded, continue?")) { return }

    $dl = Read-Host 'Folder with the downloaded files'
    $gs = Join-Path $dl 'google-services.json'; $pl = Join-Path $dl 'GoogleService-Info.plist'
    if (Test-Path $gs) { Copy-Item $gs 'src/client/calltype/android/app/'; Write-Host "✓ android/app/google-services.json" } else { Write-Warning "missing $gs" }
    if (Test-Path $pl) { Copy-Item $pl 'src/client/calltype/ios/Runner/';  Copy-Item $pl 'src/client/calltype/macos/Runner/'; Write-Host "✓ ios/Runner + macos/Runner GoogleService-Info.plist" } else { Write-Warning "missing $pl" }

    $sa = Get-ChildItem $dl -Filter '*firebase-adminsdk*.json' | Select-Object -First 1
    if (-not $sa) { $sa = Get-Item (Read-Host 'Path to the service-account JSON') }
    if (Confirm "Set Push__FcmServiceAccountJson on App Service $WebApp from $($sa.Name)? (restarts the app)") {
        # @file syntax keeps the JSON out of the command line / history.
        az webapp config appsettings set -g $Rg -n $WebApp --settings "Push__FcmServiceAccountJson=@$($sa.FullName)" --output none
        Write-Host "✓ App setting set. Delete $($sa.FullName) from disk once stored in the password manager."
    }
    Write-Host "`nSend me (Claude) the web config object + VAPID public key → I write web/firebase-messaging-sw.js and commit everything."
}

function Step-Archiver {
    Write-Host @"

== Archiver (beta, variant A) runs on YOUR Linux server (same host as PostgreSQL), not here.

  scp -r infra/archiver docs/ops/archiver-beta.sh <server>:~/jay-archiver/
  ssh <server>
  cd ~/jay-archiver && bash archiver-beta.sh

The script generates BOT_STORE_KEY, writes .env, builds the image, runs
`provision` and prints the auditor deviceId. Paste that id in the app:
Organizace → Zařízení auditora. Then `docker compose up -d`.
Full runbook: docs/ops/archiver-runbook.md
"@
}

while ($true) {
    Write-Host @"

Jay owner tasks  (repo: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD))
  1  Audit DB migrations on beta
  2  Download Android/Windows artifacts (last green deploy)
  3  Apple TestFlight secrets → GitHub
  4  Firebase config + server push secret
  5  Archiver instructions (Linux server)
  q  Quit
"@
    switch (Read-Host 'Step') {
        '1' { Step-AuditMigrations }
        '2' { Step-DownloadArtifacts }
        '3' { Step-AppleSecrets }
        '4' { Step-Firebase }
        '5' { Step-Archiver }
        'q' { return }
        default { Write-Host 'Unknown option.' }
    }
}
