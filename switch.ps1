param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("blue", "green")]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion
)

$ErrorActionPreference = "Stop"
$configPath = Join-Path $PSScriptRoot "nginx\default.conf"
$publicUrl = "http://localhost:8090"
$ports = @{ blue = 8081; green = 8082 }

function Test-App {
    param(
        [string]$BaseUrl,
        [string]$Slot,
        [string]$Version
    )

    try {
        $ready = Invoke-RestMethod "$BaseUrl/ready" -TimeoutSec 3
        $release = Invoke-RestMethod "$BaseUrl/version" -TimeoutSec 3
        $message = Invoke-RestMethod "$BaseUrl/api/message" -TimeoutSec 3

        return (
            $ready.status -eq "ready" -and
            $release.slot -eq $Slot -and
            $release.version -eq $Version -and
            $message.message -eq "Deployment lab is working" -and
            $message.version -eq $Version
        )
    }
    catch {
        return $false
    }
}

function Reload-Proxy {
    docker exec bg-proxy nginx -t
    if ($LASTEXITCODE -ne 0) {
        throw "Nginx configuration validation failed."
    }

    docker exec bg-proxy nginx -s reload
    if ($LASTEXITCODE -ne 0) {
        throw "Nginx reload failed."
    }
}

# Prevent concurrent runs of this local switching script.
$lockPath = Join-Path $PSScriptRoot ".switch.lock"

try {
    $lock = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
}
catch {
    throw "Cannot acquire deployment lock. Another switch may be running."
}

$routeChanged = $false

try {
    $oldConfig = Get-Content $configPath -Raw
    $previous = Invoke-RestMethod "$publicUrl/version" -TimeoutSec 3

    if ($previous.slot -notin @("blue", "green")) {
        throw "Cannot identify the active slot."
    }

    if ($previous.slot -eq $Target) {
        throw "$Target is already active. Choose the other slot."
    }

    $oldUpstream = "http://bg-$($previous.slot):8000"
    $newUpstream = "http://bg-${Target}:8000"

    if (-not $oldConfig.Contains($oldUpstream)) {
        throw "Saved Nginx configuration does not match the active slot."
    }

    if (-not (Test-App $publicUrl $previous.slot $previous.version)) {
        throw "Current application is unhealthy. Investigate before switching."
    }

    $candidateUrl = "http://localhost:$($ports[$Target])"

    Write-Host "Checking $Target / $ExpectedVersion..."

    if (-not (Test-App $candidateUrl $Target $ExpectedVersion)) {
        throw "Candidate checks failed. Traffic has not been switched."
    }

    $routeChanged = $true
    $oldConfig.Replace($oldUpstream, $newUpstream) |
        Set-Content -Encoding ascii $configPath

    Reload-Proxy

    Write-Host "Traffic switched to $Target."
    Write-Host "Checking the shared endpoint 15 times..."

    $failures = 0

    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 2

        if (Test-App $publicUrl $Target $ExpectedVersion) {
            $failures = 0
            Write-Host "Check ${i}: PASS"
        }
        else {
            $failures++
            Write-Host "Check ${i}: FAIL ($failures consecutive)"

            if ($failures -ge 3) {
                throw "Three consecutive post-switch checks failed."
            }
        }
    }

    if ($failures -gt 0) {
        throw "Verification window ended with an unresolved failure."
    }

    Write-Host "SUCCESS: $Target / $ExpectedVersion is active."
}
catch {
    $reason = $_.Exception.Message

    if ($routeChanged) {
        Write-Host "Switch failed: $reason"
        Write-Host "Restoring the previous route..."

        try {
            $oldConfig | Set-Content -Encoding ascii $configPath
            Reload-Proxy

            $restored = $false

            for ($i = 1; $i -le 5; $i++) {
                Start-Sleep -Seconds 2

                if (Test-App $publicUrl $previous.slot $previous.version) {
                    $restored = $true
                    break
                }
            }

            if (-not $restored) {
                throw "Previous version did not pass verification."
            }

            Write-Host "ROLLBACK VERIFIED: $($previous.slot) / $($previous.version)"
        }
        catch {
            throw "Rollback needs investigation: $($_.Exception.Message)"
        }
    }

    throw $reason
}
finally {
    $lock.Dispose()
}