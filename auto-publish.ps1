[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 > $null

$Repo = "D:\onedrive\Desktop\Code\ProxyKit"

$WatchDirs = @(
    "$Repo\incoming",
    "$Repo\icons"
)

function Publish-Git {

    param([string]$Message)

    Set-Location $Repo

    git add .

    $Status = git status --porcelain

    if ($Status) {

        git commit -m $Message

        git push

        Write-Host ""
        Write-Host "GitHub 已自动同步" -ForegroundColor Green
    }
}

function Handle-Module {

    param([string]$File)

    $IconBase = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons"

    $Ext = [System.IO.Path]::GetExtension($File).ToLower()
    $Name = [System.IO.Path]::GetFileNameWithoutExtension($File)

    switch ($Ext) {

        ".yaml" {
            $TargetDir = "$Repo\egern\modules"
        }

        ".yml" {
            $TargetDir = "$Repo\egern\modules"
        }

        ".sgmodule" {
            $TargetDir = "$Repo\surge\modules"
        }

        ".plugin" {
            $TargetDir = "$Repo\loon\plugins"
        }

        ".lpx" {
            $TargetDir = "$Repo\loon\plugins"
        }

        default {
            return
        }
    }

    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

    $Target = Join-Path $TargetDir ([System.IO.Path]::GetFileName($File))

    Copy-Item $File $Target -Force

    if ($Ext -eq ".yaml" -or $Ext -eq ".yml") {

        $IconFile = "$Name.png"
        $IconUrl = "$IconBase/$IconFile"

        $Content = Get-Content $Target -Raw

        if ($Content -notmatch "icon:") {

            if ($Content -match "description:") {

                $Content = $Content -replace "description:(.*)", "description:`$1`r`nicon: $IconUrl"

            } else {

                $Content = "icon: $IconUrl`r`n$Content"
            }

            Set-Content $Target $Content -Encoding UTF8
        }
    }

    Remove-Item $File -Force

    Publish-Git "Auto publish module $Name"

    Write-Host ""
    Write-Host "模块已自动发布: $Name" -ForegroundColor Cyan
}

function Handle-Icon {

    param([string]$File)

    $Name = [System.IO.Path]::GetFileName($File)

    Publish-Git "Auto upload icon $Name"

    Write-Host ""
    Write-Host "图标已自动上传: $Name" -ForegroundColor Yellow

    Write-Host "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/$Name"
}

foreach ($Dir in $WatchDirs) {

    $Watcher = New-Object System.IO.FileSystemWatcher

    $Watcher.Path = $Dir
    $Watcher.Filter = "*.*"
    $Watcher.IncludeSubdirectories = $false
    $Watcher.EnableRaisingEvents = $true

    Register-ObjectEvent $Watcher Created -Action {

        Start-Sleep 2

        $File = $Event.SourceEventArgs.FullPath

        $Repo = "D:\onedrive\Desktop\Code\ProxyKit"

        if ($File.StartsWith("$Repo\incoming")) {

            Handle-Module $File

        } elseif ($File.StartsWith("$Repo\icons")) {

            Handle-Icon $File
        }
    } | Out-Null
}

Write-Host ""
Write-Host "ProxyKit 全自动监听已启动" -ForegroundColor Green
Write-Host ""

while ($true) {
    Start-Sleep 5
}
