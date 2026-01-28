param(
    [Parameter(Mandatory=$true)]
    [string]$FolderPath,
    
    [Parameter(Mandatory=$false)]
    [string]$ApiUrl = "http://127.0.0.1:3333/check",
    
    [Parameter(Mandatory=$false)]
    [double]$NsfwThreshold = 0.8,
    
    [Parameter(Mandatory=$false)]
    [switch]$Recursive = $true,
    
    [Parameter(Mandatory=$false)]
    [int]$Jobs = 5,
    
    [Parameter(Mandatory=$false)]
    [switch]$Reset = $false
)

$imageExtensions = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.tiff')

$stats = @{
    Total = 0
    Processed = 0
    NSFW = 0
    Safe = 0
    Errors = 0
    Skipped = 0
}

$nsfwFiles = @()
$allResults = @()

# Progress tracking file
$progressFile = "$FolderPath\.nsfw_scan_progress.csv"
$progressData = @{}

# Handle reset option
if ($Reset) {
    if (Test-Path $progressFile) {
        Remove-Item $progressFile -Force
        Write-Host "Progress file reset. Starting fresh scan..." -ForegroundColor Yellow
    }
}

if (Test-Path $progressFile) {
    Write-Host "Found previous scan progress, resuming..." -ForegroundColor Cyan
    $csv = Import-Csv $progressFile
    if ($csv) {
        foreach ($row in $csv) {
            if ($row.Path) {
                $progressData[$row.Path] = $row
            }
        }
    }
    Write-Host "Loaded $($progressData.Count) previously scanned files" -ForegroundColor Cyan
} else {
    Write-Host "Creating new progress file..." -ForegroundColor Cyan
    @{ Path = ""; Name = ""; Size = ""; Status = ""; Result = ""; Confidence = ""; Timestamp = "" } | 
        Export-Csv $progressFile -NoTypeInformation -Force
}

if (-not (Test-Path $FolderPath -PathType Container)) {
    Write-Host "Folder not found" -ForegroundColor Red
    exit 1
}

Write-Host "Scanning images in: $FolderPath" -ForegroundColor Cyan
Write-Host ""

$files = if ($Recursive) {
    Get-ChildItem -Path $FolderPath -Recurse -File
} else {
    Get-ChildItem -Path $FolderPath -File
}

$images = $files | Where-Object {
    $ext = [System.IO.Path]::GetExtension($_.FullName).ToLower()
    $imageExtensions -contains $ext
}

$stats.Total = $images.Count

if ($stats.Total -eq 0) {
    Write-Host "No image files found" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($stats.Total) images to scan" -ForegroundColor Yellow
Write-Host "Processing with $Jobs parallel jobs"
Write-Host "======================================================"
Write-Host ""

# Script block for background jobs
$jobScript = {
    param($path, $name, $sizeMB, $apiUrl, $nsfwThreshold, $progressFile)
    
    try {
        if ((Get-Item $path).Length -gt (20GB)) {
            return @{
                Path = $path
                Name = $name
                Size = $sizeMB
                Status = "ERROR"
                Result = "Too Large"
                Confidence = ""
                Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        }
        
        $curlOutput = curl.exe -s -X POST -F "file=@$path" $apiUrl 2>$null
        $result = $curlOutput | ConvertFrom-Json
        
        if ($result.status -eq 'success') {
            $items = @($result.result)
            
            foreach ($item in $items) {
                $label = $item.label
                $conf = [math]::Round($item.confidence, 4)
                
                if ($label -eq 'nsfw' -and $conf -ge $nsfwThreshold) {
                    return @{
                        Path = $path
                        Name = $name
                        Size = $sizeMB
                        Status = "NSFW"
                        Result = "Unsafe Content"
                        Confidence = $conf
                        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    }
                }
            }
            
            return @{
                Path = $path
                Name = $name
                Size = $sizeMB
                Status = "SAFE"
                Result = "Safe Content"
                Confidence = $conf
                Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        } else {
            return @{
                Path = $path
                Name = $name
                Size = $sizeMB
                Status = "ERROR"
                Result = "API Error"
                Confidence = ""
                Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            }
        }
    }
    catch {
        return @{
            Path = $path
            Name = $name
            Size = $sizeMB
            Status = "ERROR"
            Result = $_.Exception.Message
            Confidence = ""
            Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
    }
}

$jobList = New-Object System.Collections.Generic.List[object]
$completed = 0

foreach ($file in $images) {
    if ($progressData.ContainsKey($file.FullName)) {
        Write-Host "[$completed/$($stats.Total)] $($file.Name) - SKIPPED" -ForegroundColor Gray
        $stats.Skipped++
        $completed++
        continue
    }
    
    while (($jobList | Where-Object { $_.State -eq 'Running' } | Measure-Object).Count -ge $Jobs) {
        Start-Sleep -Milliseconds 100
        
        $completed_jobs = $jobList | Where-Object { $_.State -eq 'Completed' }
        foreach ($job in $completed_jobs) {
            $result = Receive-Job $job
            $allResults += $result
            $result | Export-Csv $progressFile -Append -NoTypeInformation
            
            $color = if ($result.Status -eq 'NSFW') { 
                'Red' 
            } elseif ($result.Status -eq 'SAFE') { 
                'Green' 
            } else { 
                'Yellow' 
            }
            Write-Host "[DONE] $($result.Name) - $($result.Status) $($result.Confidence)" -ForegroundColor $color
            
            if ($result.Status -eq 'NSFW') {
                $stats.NSFW++
                $nsfwFiles += @{ Path = $result.Path; Confidence = $result.Confidence }
            } elseif ($result.Status -eq 'SAFE') {
                $stats.Safe++
            } else {
                $stats.Errors++
            }
            $stats.Processed++
            $completed++
            
            Remove-Job $job
            $jobList.Remove($job) | Out-Null
        }
    }
    
    $job = Start-Job -ScriptBlock $jobScript -ArgumentList @(
        $file.FullName, $file.Name, 
        [math]::Round($file.Length / 1MB, 2), 
        $ApiUrl, $NsfwThreshold, $progressFile
    )
    $jobList.Add($job)
    Write-Host "[JOB $($job.Id)] $($file.Name)" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Waiting for remaining jobs to complete..."
while (($jobList | Where-Object { $_.State -eq 'Running' } | Measure-Object).Count -gt 0) {
    Start-Sleep -Milliseconds 500
    
    $completed_jobs = $jobList | Where-Object { $_.State -eq 'Completed' }
    foreach ($job in $completed_jobs) {
        $result = Receive-Job $job
        $allResults += $result
        $result | Export-Csv $progressFile -Append -NoTypeInformation
        
        $color = if ($result.Status -eq 'NSFW') { 
            'Red'    
        } elseif ($result.Status -eq 'SAFE') { 
            'Green' 
        } else { 
            'Yellow' 
        }
        Write-Host "[DONE] $($result.Name) - $($result.Status) $($result.Confidence)" -ForegroundColor $color
        
        if ($result.Status -eq 'NSFW') {
            $stats.NSFW++
            $nsfwFiles += @{ Path = $result.Path; Confidence = $result.Confidence }
        } elseif ($result.Status -eq 'SAFE') {
            $stats.Safe++
        } else {
            $stats.Errors++
        }
        $stats.Processed++
        $completed++
        
        Remove-Job $job
        $jobList.Remove($job) | Out-Null
    }
}

Get-Job | Remove-Job -Force

Write-Host ""
Write-Host "======================================================"
Write-Host "SCAN COMPLETE"
Write-Host "======================================================"
Write-Host "Total: $($stats.Total) | Processed: $($stats.Processed) | Skipped: $($stats.Skipped) | Errors: $($stats.Errors)"
Write-Host "Safe: $($stats.Safe) | NSFW: $($stats.NSFW)"
Write-Host ""

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$auditFile = "$FolderPath\nsfw_audit_report_$timestamp.csv"
$allResults | Export-Csv -Path $auditFile -NoTypeInformation
Write-Host "Full audit report: $auditFile" -ForegroundColor Cyan

if ($nsfwFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "NSFW FILES:" -ForegroundColor Red
    $nsfwReportFile = "$FolderPath\nsfw_detections_$timestamp.csv"
    $nsfwFiles | Export-Csv -Path $nsfwReportFile -NoTypeInformation
    foreach ($f in $nsfwFiles) {
        Write-Host $f.Path -ForegroundColor Red
    }
    Write-Host "NSFW report: $nsfwReportFile" -ForegroundColor Red
}

Write-Host ""
Write-Host "Progress file: $progressFile" -ForegroundColor Gray
Write-Host "Done" -ForegroundColor Green
