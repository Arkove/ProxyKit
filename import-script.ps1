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
$EgernDir = "$Repo\egern\modules"

New-Item -ItemType Directory -Force -Path $QxDir | Out-Null
New-Item -ItemType Directory -Force -Path $EgernDir | Out-Null

$QxFile = "$QxDir\$FileName.conf"

Invoke-WebRequest `
    -Uri $ScriptUrl `
    -OutFile $QxFile

$IconUrl = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/$IconFile"

$EgernYaml = @"
name: $Name
description: $Name
icon: $IconUrl

scriptings:
- generic:
    name: $Name
    script_url: https://raw.githubusercontent.com/Arkove/ProxyKit/main/qx/rewrite/$FileName.conf
"@

$YamlPath = "$EgernDir\$FileName.yaml"

Set-Content `
    -Path $YamlPath `
    -Value $EgernYaml `
    -Encoding UTF8

Set-Location $Repo

git add .

git commit -m "Import $Name"

git push

$RawQx = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/qx/rewrite/$FileName.conf"

$Loon = "http://script.hub/file/_start_/$RawQx/_end_/$FileName.plugin?type=qx-rewrite&target=loon-plugin&del=true&jqEnabled=true&n=$([uri]::EscapeDataString($Name))&icon=$([uri]::EscapeDataString($IconUrl))"

$Surge = "http://script.hub/file/_start_/$RawQx/_end_/$FileName.sgmodule?type=qx-rewrite&target=surge-module&del=true&jqEnabled=true&n=$([uri]::EscapeDataString($Name))&icon=$([uri]::EscapeDataString($IconUrl))"

$Egern = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/egern/modules/$FileName.yaml"

Write-Host ""
Write-Host "====================================="
Write-Host "导入完成"
Write-Host "====================================="
Write-Host ""

Write-Host "QX:"
Write-Host $RawQx
Write-Host ""

Write-Host "Loon:"
Write-Host $Loon
Write-Host ""

Write-Host "Surge:"
Write-Host $Surge
Write-Host ""

Write-Host "Egern:"
Write-Host $Egern
Write-Host ""