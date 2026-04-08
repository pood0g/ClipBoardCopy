<#
.SYNOPSIS
    Reads a file from disk, converts to Base64, and sends it via clipboard chunks.
#>
function Send-ChunkedData {
    <#
    .PARAMETER Path
        The full path to the binary file (e.g., ncat.exe).
    .PARAMETER ChunkSize
        Size of each Base64 string segment (Default: 100,000).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$ChunkSize = 100000
    )

    if (-not (Test-Path $Path)) {
        Write-Error "File not found: $Path"
        return
    }

    Write-Host "Reading and encoding file..." -ForegroundColor Cyan
    $fileBytes = [System.IO.File]::ReadAllBytes($Path)
    $b64 = [System.Convert]::ToBase64String($fileBytes)
    $totalLength = $b64.Length

    for ($i = 0; $i -lt $totalLength; $i += $ChunkSize) {
        $take = [Math]::Min($ChunkSize, $totalLength - $i)
        $chunk = $b64.Substring($i, $take)
        
        # PS 5.1 Hash logic
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($chunk)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        $hash = (Get-FileHash -InputStream $ms -Algorithm SHA256).Hash.Substring(0, 8)
        $ms.Close()

        # Determine signal
        if ($i + $take -ge $totalLength) { $expected = "FIN" } else { $expected = "ACK" }

        # PSH Data Packet
        Set-Clipboard -Value "PSH|$i|$hash|$chunk"
        Write-Host "Sent $i/$totalLength. Waiting for $expected..." -ForegroundColor Cyan

        # Handshake: Wait for Receiver
        while ((Get-Clipboard) -ne $expected) { Start-Sleep -Milliseconds 200 }
        
        if ($expected -eq "FIN") { break }
        
        # Clear/Ready for next
        Set-Clipboard -Value "RDY"
    }

    Write-Host "Transfer complete!" -ForegroundColor Green
}

function Receive-ChunkedData {
    param([Parameter(Mandatory = $true)][string]$OutFile)

    $lastIdx = -1
    Set-Clipboard "BEGIN"
    $fileData = ""
    Write-Host "Listening for PSH packets..." -ForegroundColor Yellow

    while ($true) {
        $raw = Get-Clipboard
        if ($null -eq $raw -or $raw.Length -lt 3) { continue }

        $type = $raw.Substring(0, 3)

        if ($type -eq "PSH") {
            if ($raw -match '(?s)PSH\|(\d+)\|([A-F0-9]+)\|(.*)') {
                $idx, $hash, $data = $Matches[1], $Matches[2], $Matches[3]

                if ($idx -ne $lastIdx) {
                    $cHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($data))) -Algorithm SHA256).Hash.Substring(0, 8)
                    
                    if ($cHash -eq $hash) {
                        $fileData += $data
                        $lastIdx = $idx
                        # Signal back: Is it the final small chunk?
                        $sig = if ($data.Length -lt 100000) { "FIN" } else { "ACK" }
                        Set-Clipboard -Value $sig
                        Write-Host "[OK] $idx -> $sig" -ForegroundColor Green
                        if ($sig -eq "FIN") { break }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $fileBytes = [System.Convert]::FromBase64String($fileData)
    Set-Content -Path $OutFile -Value $fileBytes -Encoding Byte
}