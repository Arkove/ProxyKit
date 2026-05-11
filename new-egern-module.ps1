param(
    [string]$Name,
    [string]$ScriptUrl,
    [string]$IconFile,
    [string]$FileName
)

$Repo = "D:\onedrive\Desktop\Code\ProxyKit"

$YamlDir = "$Repo\egern\modules"

New-Item -ItemType Directory -Force -Path $YamlDir | Out-Null

$IconUrl = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/$IconFile"

$YamlPath = "$YamlDir\$FileName.yaml"

$Yaml = @"
name: $Name
description: $Name
icon: $IconUrl

dns: {}

scriptings:
- generic:
    name: $Name
    script_url: $ScriptUrl

widgets:
- name: $Name
  script_name: $Name
"@

Set-Content -Path $YamlPath -Value $Yaml -Encoding UTF8

Set-Location $Repo

git add .
git commit -m "Add $Name module"
git push

$Raw = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/egern/modules/$FileName.yaml"

Write-Host ""
Write-Host "模块已生成：" -ForegroundColor Green
Write-Host $Raw -ForegroundColor Cyan