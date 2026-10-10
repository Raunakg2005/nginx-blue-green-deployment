# ==============================================================================
# Comprehensive Zero-Downtime Automated Test Suite
# Tests:
#   1. Clean bootstrap on Blue (v1.0.0)
#   2. Concurrent traffic generation (10 req/s)
#   3. Zero-downtime release to Green (v2.0.0)
#   4. Zero-downtime release back to Blue (v3.0.0)
#   5. Broken build deployment test (v4.0.0-broken) with automated rollback
#   6. Complete traffic log analysis & packet loss audit
# ==============================================================================

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$logFile = Join-Path $ScriptDir "traffic_audit.log"
$stopSignalFile = Join-Path $ScriptDir ".stop_traffic_test"
if (Test-Path $logFile) { Remove-Item $logFile -Force }
if (Test-Path $stopSignalFile) { Remove-Item $stopSignalFile -Force }

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   STARTING RIGOROUS PRODUCTION TEST SUITE: ZERO-DOWNTIME" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# STEP 1: Clean Baseline Setup
Write-Host "`n>>> [PHASE 1] Initializing Clean Baseline: app-blue on v1.0.0" -ForegroundColor White
$env:APP_VERSION = "v1.0.0"
$env:SIMULATE_FAILURE_BLUE = "false"
$env:SIMULATE_FAILURE_GREEN = "false"
docker compose up -d --build app-blue nginx
Start-Sleep -Seconds 3

# Verify initial baseline
$baseResp = Invoke-RestMethod -Uri "http://localhost:8080/health" -Method Get
Write-Host "[BASELINE VERIFIED] Live Environment: $($baseResp.env.ToUpper()) | Version: $($baseResp.version)" -ForegroundColor Green

# STEP 2: Launch Background Continuous Traffic Monitor
Write-Host "`n>>> [PHASE 2] Starting High-Frequency Traffic Monitor (10 req/sec)" -ForegroundColor White

$trafficBlock = {
    param($dir, $log, $stopSignal)
    Set-Location $dir
    while (-not (Test-Path $stopSignal)) {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-RestMethod -Uri "http://localhost:8080/" -Headers @{ "Accept" = "application/json" } -TimeoutSec 2 -ErrorAction Stop
            $sw.Stop()
            $line = "[$ts] CODE=200 ENV=$($resp.env) VER=$($resp.version) MS=$([math]::Round($sw.Elapsed.TotalMilliseconds))`n"
            [System.IO.File]::AppendAllText($log, $line)
        } catch {
            $sw.Stop()
            $line = "[$ts] CODE=ERROR MSG=$($_.Exception.Message) MS=$([math]::Round($sw.Elapsed.TotalMilliseconds))`n"
            [System.IO.File]::AppendAllText($log, $line)
        }
        Start-Sleep -Milliseconds 100
    }
}

$trafficJob = Start-Job -ScriptBlock $trafficBlock -ArgumentList $ScriptDir, $logFile, $stopSignalFile
Start-Sleep -Seconds 2
Write-Host "[TRAFFIC ACTIVE] Background traffic generator running (Job ID: $($trafficJob.Id))" -ForegroundColor Cyan

# STEP 3: Deploy v2.0.0 (Blue -> Green)
Write-Host "`n>>> [PHASE 3] Executing Zero-Downtime Release: Blue (v1.0.0) -> Green (v2.0.0)" -ForegroundColor White
& .\deploy.ps1 -Version "v2.0.0"
$d1Exit = $LASTEXITCODE
if ($d1Exit -ne 0) {
    Write-Host "[FAIL] Phase 3 deployment returned non-zero code: $d1Exit" -ForegroundColor Red
} else {
    Write-Host "[PASS] Phase 3 deployment to v2.0.0 completed successfully!" -ForegroundColor Green
}

Start-Sleep -Seconds 3

# STEP 4: Deploy v3.0.0 (Green -> Blue)
Write-Host "`n>>> [PHASE 4] Executing Zero-Downtime Release: Green (v2.0.0) -> Blue (v3.0.0)" -ForegroundColor White
& .\deploy.ps1 -Version "v3.0.0"
$d2Exit = $LASTEXITCODE
if ($d2Exit -ne 0) {
    Write-Host "[FAIL] Phase 4 deployment returned non-zero code: $d2Exit" -ForegroundColor Red
} else {
    Write-Host "[PASS] Phase 4 deployment to v3.0.0 completed successfully!" -ForegroundColor Green
}

Start-Sleep -Seconds 3

# STEP 5: Deploy v4.0.0 with Simulated Failure (Testing Auto-Rollback)
Write-Host "`n>>> [PHASE 5] Executing Failure Simulation: Candidate Target Fails Health Probes" -ForegroundColor White
Write-Host "[INFO] Expecting deployment script to detect failure, abort swap, and preserve live traffic." -ForegroundColor Yellow
& .\deploy.ps1 -Version "v4.0.0-broken" -SimulateFailure
$d3Exit = $LASTEXITCODE

if ($d3Exit -eq 1) {
    Write-Host "[PASS] Phase 5 correctly caught failure and aborted with exit code 1!" -ForegroundColor Green
} else {
    Write-Host "[WARN] Phase 5 returned unexpected exit code: $d3Exit" -ForegroundColor Yellow
}

Start-Sleep -Seconds 3

# STEP 6: Stop Background Traffic Generator & Analyze Audit Log
Write-Host "`n>>> [PHASE 6] Stopping Traffic Generator & Conducting Audit Analysis" -ForegroundColor White
Set-Content -Path $stopSignalFile -Value "STOP"
Start-Sleep -Seconds 1
Stop-Job $trafficJob -ErrorAction SilentlyContinue
Remove-Job $trafficJob -ErrorAction SilentlyContinue
if (Test-Path $stopSignalFile) { Remove-Item $stopSignalFile -Force }

# Audit Log Analysis
if (-not (Test-Path $logFile)) {
    Write-Host "[ERROR] Traffic audit log was not generated!" -ForegroundColor Red
    exit 1
}

$lines = Get-Content $logFile
$totalRequests = $lines.Count
$successRequests = ($lines | Select-String -Pattern "CODE=200").Count
$errorRequests = $totalRequests - $successRequests

$blueCount = ($lines | Select-String -Pattern "ENV=blue").Count
$greenCount = ($lines | Select-String -Pattern "ENV=green").Count

$v1Count = ($lines | Select-String -Pattern "VER=v1.0.0").Count
$v2Count = ($lines | Select-String -Pattern "VER=v2.0.0").Count
$v3Count = ($lines | Select-String -Pattern "VER=v3.0.0").Count

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host "                FINAL TRAFFIC & PACKET AUDIT REPORT" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Total Requests Dispatched:        $totalRequests"
Write-Host "Successful 200 OK Responses:      $successRequests" -ForegroundColor Green
Write-Host "Dropped / Non-200 Responses:      $errorRequests" -ForegroundColor $(if ($errorRequests -eq 0) { "Green" } else { "Red" })

Write-Host "`nTraffic Distribution Across Environments:" -ForegroundColor White
Write-Host "  Requests served by Blue:        $blueCount"
Write-Host "  Requests served by Green:       $greenCount"

Write-Host "`nTraffic Distribution Across Deployed Versions:" -ForegroundColor White
Write-Host "  Requests on v1.0.0:             $v1Count"
Write-Host "  Requests on v2.0.0:             $v2Count"
Write-Host "  Requests on v3.0.0:             $v3Count"

if ($totalRequests -gt 0) {
    $deliveryRate = [math]::Round(($successRequests / $totalRequests) * 100, 2)
    Write-Host "`nPacket Delivery Success Rate:     ${deliveryRate}%" -ForegroundColor Green
}

if ($errorRequests -eq 0 -and $totalRequests -gt 0) {
    Write-Host "`n=================================================================" -ForegroundColor Green
    Write-Host "   ZERO DOWNTIME PROVEN: 100.0% SUCCESS, 0 DROPPED REQUESTS!" -ForegroundColor Green
    Write-Host "=================================================================" -ForegroundColor Green
} else {
    Write-Host "`n=================================================================" -ForegroundColor Red
    Write-Host "   AUDIT FAILED: $errorRequests REQUESTS DROPPED!" -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
}
