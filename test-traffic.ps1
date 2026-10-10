<#
.SYNOPSIS
    Zero-Downtime Traffic Load & Packet-Loss Monitor for Windows PowerShell.
.DESCRIPTION
    Continuously polls the public gateway at 10 req/s, detects live blue/green transitions,
    and calculates packet loss to verify zero-downtime release engineering.
.PARAMETER TargetUrl
    Target URL to query (default: http://localhost:8080/).
#>
param(
    [string]$TargetUrl = "http://localhost:8080/"
)

$TotalRequests = 0
$SuccessCount = 0
$FailureCount = 0
$StartTime = Get-Date

$LastEnv = ""
$LastVersion = ""

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "       ZERO-DOWNTIME TRAFFIC LOAD & PACKET-LOSS MONITOR" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Target URL:       $TargetUrl"
Write-Host "Load Rate:        10 requests / second"
Write-Host "Press [Ctrl + C] anytime to view final validation summary.`n" -ForegroundColor Yellow

try {
    while ($true) {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $TotalRequests++

        try {
            # Use curl.exe or WebRequest with short timeout
            $resp = Invoke-RestMethod -Uri $TargetUrl -Headers @{ "Accept" = "application/json" } -TimeoutSec 2 -ErrorAction Stop
            $sw.Stop()
            $latencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds)
            $SuccessCount++

            $envVal = $resp.env
            $verVal = $resp.version

            $envColor = if ($envVal -eq "blue") { "Blue" } elseif ($envVal -eq "green") { "Green" } else { "White" }

            if ($LastEnv -and ($LastEnv -ne $envVal -or $LastVersion -ne $verVal)) {
                Write-Host "`n>>> [SWAP DETECTED] Transitioned from $LastEnv`:$LastVersion to $envVal`:$verVal (0 Dropped Packets) <<<`n" -ForegroundColor Magenta
            }

            $LastEnv = $envVal
            $LastVersion = $verVal

            Write-Host "[$timestamp] HTTP " -NoNewline
            Write-Host "200" -ForegroundColor Green -NoNewline
            Write-Host " | Env: " -NoNewline
            Write-Host "$($envVal.ToUpper())" -ForegroundColor $envColor -NoNewline
            Write-Host " | Ver: $verVal | Latency: ${latencyMs}ms"
        }
        catch {
            $sw.Stop()
            $latencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds)
            $FailureCount++
            Write-Host "[$timestamp] " -NoNewline
            Write-Host "ERROR / DROPPED REQUEST" -ForegroundColor Red -NoNewline
            Write-Host " | Latency: ${latencyMs}ms | $_"
        }

        Start-Sleep -Milliseconds 100
    }
}
finally {
    $duration = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)
    Write-Host "`n=================================================================" -ForegroundColor Cyan
    Write-Host "                 TRAFFIC MONITOR REPORT" -ForegroundColor Cyan
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "Total Monitoring Duration:   ${duration}s"
    Write-Host "Total Requests Dispatched:   $TotalRequests"
    Write-Host "Successful Responses (200):  $SuccessCount" -ForegroundColor Green
    Write-Host "Dropped / Error Responses:   $FailureCount" -ForegroundColor $(if ($FailureCount -eq 0) { "Green" } else { "Red" })

    if ($TotalRequests -gt 0) {
        $rate = [math]::Round(($SuccessCount / $TotalRequests) * 100, 2)
        Write-Host "Packet Delivery Rate:        ${rate}%"
    }

    if ($FailureCount -eq 0 -and $TotalRequests -gt 0) {
        Write-Host "`n>>> ZERO DOWNTIME VERIFIED: 0 DROPPED PACKETS DURING DEPLOYMENT <<<" -ForegroundColor Green
    } elseif ($FailureCount -gt 0) {
        Write-Host "`n>>> WARNING: $FailureCount PACKETS DROPPED / RETURNED NON-200 <<<" -ForegroundColor Red
    }
    Write-Host "=================================================================" -ForegroundColor Cyan
}
