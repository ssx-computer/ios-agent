$ErrorActionPreference = "Continue"
Set-Location C:\Users\ssx\ios-agent
$ok = $false
for ($i = 1; $i -le 8; $i++) {
    Write-Host "=== push attempt $i ==="
    $out = git push origin main 2>&1 | Out-String
    Write-Host $out.Trim()
    if ($out -match "main -> main") { $ok = $true; break }
    Start-Sleep -Seconds 60
}
if ($ok) { Write-Host "PUSH OK" } else { Write-Host "PUSH FAILED after retries" }
