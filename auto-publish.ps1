$Repo = "D:\onedrive\Desktop\Code\ProxyKit"
$Incoming = "$Repo\incoming"
$IconBase = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons"

Set-Location $Repo

$Files = Get-ChildItem $Incoming

foreach ($File in $Files) {

    $Ext = $File.Extension.ToLower()
    $Name = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)

    switch ($Ext) {

        ".yaml" {
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
            continue
        }
    }

    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null

    $Target = Join-Path $TargetDir $File.Name

    Copy-Item $File.FullName $Target -Force

    if ($Ext -eq ".yaml") {

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

    Remove-Item $File.FullName -Force
}

git add .
git commit -m "Auto publish modules"
git push

Write-Host ""
Write-Host "全部模块已自动发布" -ForegroundColor Green