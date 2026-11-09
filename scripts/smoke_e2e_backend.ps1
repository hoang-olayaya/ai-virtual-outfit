# ==============================================================================
# AI Virtual Outfit Preview - Repeatable End-to-End Smoke Test
# Exercises the entire live Backend system (FastAPI, Redis, Celery Worker,
# PostgreSQL, Local Storage) using FakeAIProvider (0 VND, 100% deterministic).
# ==============================================================================

param(
    [string]$BaseUrl = "http://localhost:8000"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PersonImgPath = Join-Path $ScriptDir "temp_smoke_person.jpg"
$GarmentImgPath = Join-Path $ScriptDir "temp_smoke_garment.png"
$DownloadedResult = Join-Path $ScriptDir "temp_smoke_result.jpg"

function Print-Step($num, $msg) {
    Write-Host "`n[STEP $num] $msg" -ForegroundColor Cyan
}

function Assert-Condition($condition, $msg) {
    if (-not $condition) {
        Write-Host " [FAILED] $msg" -ForegroundColor Red
        throw "Assertion failed: $msg"
    } else {
        Write-Host " [PASS] $msg" -ForegroundColor Green
    }
}

Write-Host "=================================================================" -ForegroundColor Yellow
Write-Host " AI VIRTUAL OUTFIT - REPEATABLE E2E SMOKE TEST" -ForegroundColor Yellow
Write-Host " Target API: $BaseUrl" -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Yellow

try {
    # --------------------------------------------------------------------------
    # STEP 0: Generate synthetic test images
    # --------------------------------------------------------------------------
    Print-Step 0 "Generating synthetic JPEG & PNG sample images..."
    & backend\.venv\Scripts\python.exe -c @"
from PIL import Image, ImageDraw
p = Image.new('RGB', (256, 384), color=(240, 240, 245))
d = ImageDraw.Draw(p)
d.rectangle((64, 64, 192, 320), fill=(50, 100, 200))
p.save('$($PersonImgPath.Replace('\', '/'))', 'JPEG', quality=95)

g = Image.new('RGB', (256, 256), color=(255, 255, 255))
d2 = ImageDraw.Draw(g)
d2.rectangle((40, 40, 216, 216), fill=(200, 50, 50))
g.save('$($GarmentImgPath.Replace('\', '/'))', 'PNG')
"@
    Assert-Condition (Test-Path $PersonImgPath) "Synthetic person image generated: $PersonImgPath"
    Assert-Condition (Test-Path $GarmentImgPath) "Synthetic garment image generated: $GarmentImgPath"

    # --------------------------------------------------------------------------
    # STEP 1: Healthcheck & Readiness probes
    # --------------------------------------------------------------------------
    Print-Step 1 "Checking API liveness (/health) and readiness (/api/v1/health/ready)..."
    $healthRaw = curl.exe -s "$BaseUrl/health"
    $health = $healthRaw | ConvertFrom-Json
    Assert-Condition ($health.status -eq "ok") "Liveness check: status is 'ok'"

    $readyRaw = curl.exe -s "$BaseUrl/api/v1/health/ready"
    $ready = $readyRaw | ConvertFrom-Json
    Assert-Condition ($ready.status -eq "ready") "Readiness check: status is 'ready'"
    Assert-Condition ($ready.checks.database -eq "connected") "Readiness check: PostgreSQL is connected"
    Assert-Condition ($ready.checks.redis -eq "connected") "Readiness check: Redis broker is connected"

    # --------------------------------------------------------------------------
    # STEP 2: POST /api/v1/try-ons (Submit new try-on job)
    # --------------------------------------------------------------------------
    $idempKey = "e2e-smoke-" + [guid]::NewGuid().ToString("N")
    Print-Step 2 "Submitting new try-on job with Idempotency-Key: $idempKey..."
    $postRaw = curl.exe -s -w "\n%{http_code}" -X POST "$BaseUrl/api/v1/try-ons" `
        -H "Idempotency-Key: $idempKey" `
        -F "person_image=@$PersonImgPath" `
        -F "garment_image=@$GarmentImgPath"

    $lines = $postRaw -split "`n"
    $statusCode = [int]($lines[-1].Trim())
    $bodyJson = ($lines[0..($lines.Length - 2)]) -join "`n"
    $jobObj = $bodyJson | ConvertFrom-Json

    Assert-Condition ($statusCode -eq 202) "HTTP Status Code is 202 Accepted (actual: $statusCode)"
    Assert-Condition ($null -ne $jobObj.job_id) "Returned valid Job ID: $($jobObj.job_id)"
    Assert-Condition ($jobObj.status -eq "queued") "Initial job status is 'queued'"
    $jobId = $jobObj.job_id

    # --------------------------------------------------------------------------
    # STEP 3: Test Idempotent Submission (Duplicate POST with same key)
    # --------------------------------------------------------------------------
    Print-Step 3 "Testing Idempotency: Re-submitting same Idempotency-Key..."
    $dupRaw = curl.exe -s -w "\n%{http_code}" -X POST "$BaseUrl/api/v1/try-ons" `
        -H "Idempotency-Key: $idempKey" `
        -F "person_image=@$PersonImgPath" `
        -F "garment_image=@$GarmentImgPath"

    $dupLines = $dupRaw -split "`n"
    $dupCode = [int]($dupLines[-1].Trim())
    $dupBody = ($dupLines[0..($dupLines.Length - 2)]) -join "`n"
    $dupObj = $dupBody | ConvertFrom-Json
    Assert-Condition ($dupCode -in @(200, 202)) "Duplicate POST returned HTTP $dupCode"
    Assert-Condition ($dupObj.job_id -eq $jobId) "Duplicate POST returned identical Job ID: $($dupObj.job_id)"

    # --------------------------------------------------------------------------
    # STEP 4: Poll GET /api/v1/try-ons/{id} until succeeded
    # --------------------------------------------------------------------------
    Print-Step 4 "Polling job status for ID $jobId until succeeded..."
    $maxAttempts = 30
    $attempt = 0
    $finalStatus = "queued"

    while ($attempt -lt $maxAttempts) {
        Start-Sleep -Seconds 1
        $attempt++
        $statusRaw = curl.exe -s "$BaseUrl/api/v1/try-ons/$jobId"
        $statusObj = $statusRaw | ConvertFrom-Json
        $finalStatus = $statusObj.status
        Write-Host "   Polling [$attempt/$maxAttempts]: status = $finalStatus" -ForegroundColor DarkGray
        if ($finalStatus -in @("succeeded", "failed")) {
            break
        }
    }

    Assert-Condition ($finalStatus -eq "succeeded") "Job completed with status 'succeeded' (actual: $finalStatus)"
    Assert-Condition ($null -eq $statusObj.error_code) "error_code is null"
    Assert-Condition ($null -ne $statusObj.result_image_url) "result_image_url is present: $($statusObj.result_image_url)"

    # --------------------------------------------------------------------------
    # STEP 5: GET /api/v1/try-ons/{id}/image (Result image stream & cache headers)
    # --------------------------------------------------------------------------
    Print-Step 5 "Downloading result image and verifying Cache-Control headers..."
    $imgHeaders = curl.exe -s -D - "$BaseUrl/api/v1/try-ons/$jobId/image" --output "$DownloadedResult"
    $cacheLine = ($imgHeaders | Select-String -Pattern "cache-control:" -CaseSensitive:$false)
    $cacheControlHeader = if ($cacheLine) { $cacheLine.ToString().Trim() } else { "" }
    Write-Host "   Headers returned: $cacheControlHeader" -ForegroundColor DarkGray
    Assert-Condition ($cacheControlHeader -like "*no-store*" -or $cacheControlHeader -like "*private*") "Cache-Control header contains strict privacy directives"

    $fileInfo = Get-Item "$DownloadedResult"
    Assert-Condition ($fileInfo.Length -gt 0) "Downloaded result image size: $($fileInfo.Length) bytes"

    # --------------------------------------------------------------------------
    # STEP 6: GET input images for compare (/inputs/person and /inputs/garment)
    # --------------------------------------------------------------------------
    Print-Step 6 "Fetching input media images for comparison..."
    $personCode = curl.exe -s -o /dev/null -w "%{http_code}" "$BaseUrl/api/v1/try-ons/$jobId/inputs/person"
    Assert-Condition ($personCode -eq "200") "GET /inputs/person returned HTTP 200"

    $garmentCode = curl.exe -s -o /dev/null -w "%{http_code}" "$BaseUrl/api/v1/try-ons/$jobId/inputs/garment"
    Assert-Condition ($garmentCode -eq "200") "GET /inputs/garment returned HTTP 200"

    # --------------------------------------------------------------------------
    # STEP 7: POST /api/v1/try-ons/{id}/save (Save to history)
    # --------------------------------------------------------------------------
    Print-Step 7 "Saving job to History (POST /api/v1/try-ons/$jobId/save)..."
    $saveRaw = curl.exe -s -w "\n%{http_code}" -X POST "$BaseUrl/api/v1/try-ons/$jobId/save"
    $saveLines = $saveRaw -split "`n"
    $saveCode = [int]($saveLines[-1].Trim())
    $saveBody = ($saveLines[0..($saveLines.Length - 2)]) -join "`n"
    $saveObj = $saveBody | ConvertFrom-Json

    Assert-Condition ($saveCode -eq 200) "Save returned HTTP 200 (actual: $saveCode)"
    Assert-Condition ($saveObj.is_saved -eq $true) "Job is_saved is true"
    Assert-Condition ($null -ne $saveObj.saved_at) "Job saved_at timestamp: $($saveObj.saved_at)"
    $initialSavedAt = $saveObj.saved_at

    # --------------------------------------------------------------------------
    # STEP 8: Test Save Idempotency (Duplicate save request)
    # --------------------------------------------------------------------------
    Print-Step 8 "Testing Save Idempotency: Duplicate POST save..."
    $saveDupRaw = curl.exe -s -w "\n%{http_code}" -X POST "$BaseUrl/api/v1/try-ons/$jobId/save"
    $saveDupLines = $saveDupRaw -split "`n"
    $saveDupCode = [int]($saveDupLines[-1].Trim())
    $saveDupObj = (($saveDupLines[0..($saveDupLines.Length - 2)]) -join "`n") | ConvertFrom-Json

    Assert-Condition ($saveDupCode -eq 200) "Duplicate save returned HTTP 200"
    Assert-Condition ($saveDupObj.saved_at -eq $initialSavedAt) "saved_at is immutable across repeated calls"

    # --------------------------------------------------------------------------
    # STEP 9: GET /api/v1/history & GET /api/v1/history/{id}
    # --------------------------------------------------------------------------
    Print-Step 9 "Querying History list and History detail..."
    $historyRaw = curl.exe -s "$BaseUrl/api/v1/history?limit=10&offset=0"
    $historyObj = $historyRaw | ConvertFrom-Json
    $foundInHistory = $false
    foreach ($item in $historyObj.items) {
        if ($item.job_id -eq $jobId) {
            $foundInHistory = $true
            break
        }
    }
    Assert-Condition ($foundInHistory -eq $true) "Saved job is present in History list (total: $($historyObj.total))"

    $detailRaw = curl.exe -s "$BaseUrl/api/v1/history/$jobId"
    $detailObj = $detailRaw | ConvertFrom-Json
    Assert-Condition ($detailObj.job_id -eq $jobId) "History detail ID matches: $($detailObj.job_id)"
    Assert-Condition ($detailObj.is_saved -eq $true) "History detail is_saved is true"

    # --------------------------------------------------------------------------
    # STEP 10: DELETE /api/v1/history/{id} (Deletion and 404 verification)
    # --------------------------------------------------------------------------
    Print-Step 10 "Deleting item from History (DELETE /api/v1/history/$jobId)..."
    $delCode = curl.exe -s -o /dev/null -w "%{http_code}" -X DELETE "$BaseUrl/api/v1/history/$jobId"
    Assert-Condition ($delCode -eq "204") "DELETE /history/$jobId returned HTTP 204 No Content"

    $getAfterDel = curl.exe -s -o /dev/null -w "%{http_code}" "$BaseUrl/api/v1/history/$jobId"
    Assert-Condition ($getAfterDel -eq "404") "GET /history/$jobId after deletion returned HTTP 404 Not Found"

    Write-Host "`n=================================================================" -ForegroundColor Green
    Write-Host " ALL 10 E2E SMOKE TEST STEPS PASSED SUCCESSFULLY! " -ForegroundColor Green
    Write-Host "=================================================================" -ForegroundColor Green
}
finally {
    # Cleanup temporary test files
    Remove-Item $PersonImgPath -ErrorAction SilentlyContinue
    Remove-Item $GarmentImgPath -ErrorAction SilentlyContinue
    Remove-Item $DownloadedResult -ErrorAction SilentlyContinue
}
