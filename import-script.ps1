param(
    [string]$Name,
    [string]$ScriptUrl,
    [string]$IconFile,
    [string]$FileName
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
chcp 65001 > $null

$Repo = "D:\onedrive\Desktop\Code\ProxyKit"

$QxDir = "$Repo\qx\rewrite"
$LoonDir = "$Repo\loon\plugins"
$SurgeDir = "$Repo\surge\modules"
$EgernDir = "$Repo\egern\modules"

New-Item -ItemType Directory -Force -Path $QxDir | Out-Null
New-Item -ItemType Directory -Force -Path $LoonDir | Out-Null
New-Item -ItemType Directory -Force -Path $SurgeDir | Out-Null
New-Item -ItemType Directory -Force -Path $EgernDir | Out-Null

$QxFile = "$QxDir\$FileName.conf"
$LoonFile = "$LoonDir\$FileName.plugin"
$SurgeFile = "$SurgeDir\$FileName.sgmodule"
$YamlFile = "$EgernDir\$FileName.yaml"

Invoke-WebRequest `
    -Uri $ScriptUrl `
    -OutFile $QxFile

$RawContent = Get-Content $QxFile -Raw

$IconUrl = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/$IconFile"

$LoonContent = @"
#!name=$Name
#!icon=$IconUrl

$RawContent
"@

Set-Content `
    -Path $LoonFile `
    -Value $LoonContent `
    -Encoding UTF8

$SurgeContent = @"
#!name=$Name
#!icon=$IconUrl

$RawContent
"@

Set-Content `
    -Path $SurgeFile `
    -Value $SurgeContent `
    -Encoding UTF8

$YamlContent = @"
name: $Name
description: $Name
icon: $IconUrl

scriptings:
- generic:
    name: $Name
    script_url: https://raw.githubusercontent.com/Arkove/ProxyKit/main/qx/rewrite/$FileName.conf
"@

Set-Content `
    -Path $YamlFile `
    -Value $YamlContent `
    -Encoding UTF8

Set-Location $Repo

git add .

git commit -m "Import $Name"

git push

Write-Host ""
Write-Host "====================================="
Write-Host "四端同步完成"
Write-Host "====================================="
Write-Host ""

Write-Host "QX:"
Write-Host "https://raw.githubusercontent.com/Arkove/ProxyKit/main/qx/rewrite/$FileName.conf"
Write-Host ""

Write-Host "Loon:"
Write-Host "https://raw.githubusercontent.com/Arkove/ProxyKit/main/loon/plugins/$FileName.plugin"
Write-Host ""

Write-Host "Surge:"
Write-Host "https://raw.githubusercontent.com/Arkove/ProxyKit/main/surge/modules/$FileName.sgmodule"
Write-Host ""

Write-Host "Egern:"
Write-Host "https://raw.githubusercontent.com/Arkove/ProxyKit/main/egern/modules/$FileName.yaml"
Write-Host ""