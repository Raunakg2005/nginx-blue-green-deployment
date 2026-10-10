<#
.SYNOPSIS
    Zero-Downtime Blue-Green Deployment Automation for Windows PowerShell.
.DESCRIPTION
    Automates zero-downtime blue-green release switching using Docker Compose and Nginx.
.PARAMETER Version
    The application version tag to deploy (e.g. v2.0.0).
.PARAMETER SimulateFailure
    Simulates an unhealthy deployment to demonstrate automated rollback.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version,

    [switch]$SimulateFailure
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$StateFile = Join-Path $ScriptDir ".active_env"
$UpstreamConf = Join-Path $ScriptDir "nginx/conf.d/upstream.conf"
$HealthMaxRetries = 15
$HealthRetryInterval = 2
$DrainWaitSeconds = 7

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   ZERO-DOWNTIME BLUE-GREEN APPLICATION DEPLOYMENT AUTOMATION" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# Step 1: Detect Active Environment
Write-Host "`n===> Step 1: Detecting Currently Active Environment" -ForegroundColor White

$ActiveEnv = ""
if (Test-Path $StateFile) {
    $ActiveEnv = (Get-Content $StateFile -Raw).Trim()
}

if ($ActiveEnv -ne "blue" -and $ActiveEnv -ne "green") {
    if (Test-Path $UpstreamConf) {
        $confContent = Get-Content $UpstreamConf -Raw
        if ($confContent -match "app-green") {
            $ActiveEnv = "green"
        } else {
            $ActiveEnv = "blue"
        }
    } else {
        $ActiveEnv = "blue"
    }
}

if ($ActiveEnv -eq "blue") {
    $TargetEnv = "green"
    $TargetService = "app-green"
    $TargetPort = 8082
    $PrevService = "app-blue"
    $PrevPort = 8081
    $ActiveColor = "Blue"
    $TargetColor = "Green"
} else {
    $TargetEnv = "blue"
    $TargetService = "app-blue"
    $TargetPort = 8081
    $PrevService = "app-green"
    $PrevPort = 8082
    $ActiveColor = "Green"
    $TargetColor = "Blue"
}

Write-Host "Currently Active Environment: " -NoNewline
Write-Host $ActiveEnv.ToUpper() -ForegroundColor $ActiveColor
Write-Host "Target Deployment Candidate:  " -NoNewline
Write-Host $TargetEnv.ToUpper() -ForegroundColor $TargetColor
Write-Host "Target Port:                  $TargetPort"
Write-Host "Release Version:              $Version"
if ($SimulateFailure) {
    Write-Host "Simulation Mode:              SIMULATE_FAILURE ENABLED (Test Rollback)" -ForegroundColor Yellow
}

# Step 2: Build & Start Target Environment
Write-Host "`n===> Step 2: Building & Provisioning Target Container [$TargetService]" -ForegroundColor White

$env:APP_VERSION = $Version
if ($TargetEnv -eq "green") {
    $env:SIMULATE_FAILURE_GREEN = if ($SimulateFailure) { "true" } else { "false" }
    $env:SIMULATE_FAILURE_BLUE = "false"
} else {
    $env:SIMULATE_FAILURE_BLUE = if ($SimulateFailure) { "true" } else { "false" }
    $env:SIMULATE_FAILURE_GREEN = "false"
}
$envContent = @"
APP_VERSION=$Version
SIMULATE_FAILURE_BLUE=$($env:SIMULATE_FAILURE_BLUE)
SIMULATE_FAILURE_GREEN=$($env:SIMULATE_FAILURE_GREEN)
"@
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $ScriptDir ".env"), $envContent, $utf8NoBom)

Write-Host "[INFO] Executing: docker compose up -d --build $TargetService" -ForegroundColor Cyan
docker compose up -d --build $TargetService
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to start container $TargetService" -ForegroundColor Red
    exit 1
}

# Step 3: Health Check Probe Loop
Write-Host "`n===> Step 3: Performing Automated Health Probes on [$TargetService:http://127.0.0.1:$TargetPort/health]" -ForegroundColor White
$HealthPassed = $false
$ProbeUrl = "http://127.0.0.1:$TargetPort/health"

for ($i = 1; $i -le $HealthMaxRetries; $i++) {
    try {
        $resp = Invoke-RestMethod -Uri $ProbeUrl -Method Get -TimeoutSec 3 -ErrorAction Stop
        if ($resp.status -eq "UP") {
            Write-Host "[SUCCESS] Attempt $i/$HealthMaxRetries`: Healthy! HTTP 200 OK (Status=$($resp.status), Version=$($resp.version))" -ForegroundColor Green
            $HealthPassed = $true
            break
        } else {
            Write-Host "[WARN] Attempt $i/$HealthMaxRetries`: Received unexpected status '$($resp.status)'. Retrying in ${HealthRetryInterval}s..." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[WARN] Attempt $i/$HealthMaxRetries`: Probe failed. Retrying in ${HealthRetryInterval}s..." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds $HealthRetryInterval
}

# Step 4: Handle Failure & Rollback
if (-not $HealthPassed) {
    Write-Host "`n=================================================================" -ForegroundColor Red
    Write-Host "  DEPLOYMENT ABORTED: HEALTH CHECK FAILED FOR $($TargetEnv.ToUpper())" -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host "[ERROR] Candidate container $TargetService failed health validation." -ForegroundColor Red
    Write-Host "[WARN] Initiating automated rollback: Nginx configuration left untouched." -ForegroundColor Yellow
    Write-Host "[INFO] Stopping unhealthy container $TargetService..." -ForegroundColor Cyan
    docker compose stop $TargetService
    Write-Host "[SUCCESS] Rollback complete. Environment $($ActiveEnv.ToUpper()) continues serving all live traffic." -ForegroundColor Green
    exit 1
}

# Step 5: Atomic Upstream Swap
Write-Host "`n===> Step 5: Atomically Updating Nginx Upstream Configuration" -ForegroundColor White
$newUpstream = @"
# Dynamically managed upstream configuration
# Updated by deploy.ps1 on $([DateTime]::UtcNow.ToString("o"))
upstream active_app {
    server ${TargetService}:${TargetPort};
    keepalive 32;
}
"@

$tmpFile = "$UpstreamConf.tmp"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmpFile, $newUpstream, $utf8NoBom)
Move-Item -Path $tmpFile -Destination $UpstreamConf -Force
Write-Host "[SUCCESS] Nginx upstream pointed to: $TargetService`:$TargetPort" -ForegroundColor Green

# Step 6: Test & Reload Nginx
Write-Host "`n===> Step 6: Validating Nginx Configuration & Graceful Reload" -ForegroundColor White
docker compose exec -T nginx nginx -t
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Nginx configuration test failed!" -ForegroundColor Red
    exit 1
}

docker compose exec -T nginx nginx -s reload
Write-Host "[SUCCESS] Nginx dynamically reloaded without dropping connections." -ForegroundColor Green

# Step 7: Connection Draining
Write-Host "`n===> Step 7: Draining Active In-Flight Connections (${DrainWaitSeconds}s)" -ForegroundColor White
Start-Sleep -Seconds $DrainWaitSeconds

# Step 8: Decommission Previous Environment
Write-Host "`n===> Step 8: Decommissioning Previous Container [$PrevService]" -ForegroundColor White
docker compose stop $PrevService
Write-Host "[SUCCESS] Previous container $PrevService stopped cleanly." -ForegroundColor Green

[System.IO.File]::WriteAllText($StateFile, "$TargetEnv`n", $utf8NoBom)

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host "       ZERO-DOWNTIME DEPLOYMENT COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "Previous Environment: $ActiveEnv"
Write-Host "Live Environment:     $TargetEnv" -ForegroundColor $TargetColor
Write-Host "Active Version:       $Version"
Write-Host "Public Gateway:       http://localhost:8080/" -ForegroundColor Cyan
Write-Host "Health Probe:         http://localhost:8080/health" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Green
