<#
Staticize-EgernModules.ps1

用途：
将 Egern 配置中的 ScriptHub 动态转译链接、Manifest 指定的模块链接，静态化到自己的 ProxyKit 仓库。

主要能力：
1. 支持 ConfigPath 扫描 modules: 中的 script.hub 链接。
2. 支持 ManifestPath 手动指定资源。
3. 对 .lpx / .plugin / .sgmodule / .yaml / .yml 直接镜像，不再长期依赖 ScriptHub。
4. 对 JS / QX rewrite 等非完整模块，可尝试走 ScriptHub 转译；若本地 PowerShell 无法访问 script.hub，会记录失败。
5. 支持 PreserveMetadata=true，保留原模块 name / desc / author / homepage / icon / date 等介绍。
6. 支持 IconUrl，直接指定远程图标。
7. 支持 IconFile，自动拼接为本仓库 icons 下的 raw 链接。
8. 修正 Loon 源 .lpx 默认输出为 .plugin，不再错误输出为 .sgmodule。
9. GitPush 时只 add 本脚本生成的模块文件和日志，不再 git add .，避免误传敏感配置。
#>

param(
    [string]$Repo = "D:\onedrive\Desktop\Code\ProxyKit",
    [string]$ConfigPath = "",
    [string]$ManifestPath = "",
    [string]$GithubRepo = "Arkove/ProxyKit",
    [string]$Branch = "main",
    [switch]$OverwriteConfig,
    [switch]$GitPush,
    [string]$CommitMessage = "Staticize Egern modules",
    [int]$TimeoutSec = 60,
    [int]$Retry = 3,
    [switch]$ForceScriptHub,
    [switch]$SkipConfigScan
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

try {
    chcp 65001 > $null
} catch {}

function Test-Truthy {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value.Trim() -match '^(?i:true|1|yes|y)$'
}

function Get-PropValue {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Default = ""
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $value = $Object.$Name
        if ($null -eq $value) {
            return $Default
        }
        return [string]$value
    }

    return $Default
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Ensure-Dir {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Normalize-GitHubRawUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $Url
    }

    $u = $Url.Trim()

    $u = $u -replace '^http://raw\.githubusercontent\.com/', 'https://raw.githubusercontent.com/'

    if ($u -match '^https://github\.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$') {
        return "https://raw.githubusercontent.com/$($Matches[1])/$($Matches[2])/$($Matches[3])/$($Matches[4])"
    }

    if ($u -match '^https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$') {
        return "https://raw.githubusercontent.com/$($Matches[1])/$($Matches[2])/$($Matches[3])/$($Matches[4])"
    }

    return $u
}

function UrlDecodeSafe {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    try {
        return [System.Uri]::UnescapeDataString($Text.Replace('+', ' '))
    } catch {
        return $Text
    }
}

function Parse-Query {
    param([string]$Query)

    $dict = @{}

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return $dict
    }

    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) {
            continue
        }

        $kv = $pair.Split('=', 2)
        $key = UrlDecodeSafe $kv[0]
        $val = if ($kv.Count -gt 1) { UrlDecodeSafe $kv[1] } else { "" }

        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $dict[$key] = $val
        }
    }

    return $dict
}

function Parse-HeadersText {
    param([string]$HeadersText)

    $headers = @{}

    if ([string]::IsNullOrWhiteSpace($HeadersText)) {
        return $headers
    }

    $text = UrlDecodeSafe $HeadersText

    foreach ($part in $text.Split(';')) {
        $p = $part.Trim()

        if ([string]::IsNullOrWhiteSpace($p)) {
            continue
        }

        if ($p -match '^\s*([^:=]+)\s*[:=]\s*(.+?)\s*$') {
            $headers[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    return $headers
}

function Merge-Headers {
    param(
        [hashtable]$Base,
        [hashtable]$Extra
    )

    $result = @{}

    foreach ($k in $Base.Keys) {
        $result[$k] = $Base[$k]
    }

    foreach ($k in $Extra.Keys) {
        $result[$k] = $Extra[$k]
    }

    return $result
}

function Parse-ScriptHubUrl {
    param([string]$Url)

    $result = [ordered]@{
        IsScriptHub = $false
        SourceUrl = ""
        OutputName = ""
        Query = @{}
        Type = ""
        Target = ""
        IconUrl = ""
        HeadersText = ""
        NormalizedScriptHubUrl = ""
    }

    if ($Url -notmatch 'https?://script\.hub/file/_start_/(.+?)/_end_/([^?]+)(\?.*)?$') {
        return [pscustomobject]$result
    }

    $result.IsScriptHub = $true

    $source = UrlDecodeSafe $Matches[1]
    $output = UrlDecodeSafe $Matches[2]
    $query = if ($Matches[3]) { $Matches[3] } else { "" }

    $q = Parse-Query $query

    $result.SourceUrl = Normalize-GitHubRawUrl $source
    $result.OutputName = $output
    $result.Query = $q
    $result.Type = if ($q.ContainsKey('type')) { $q['type'] } else { "" }
    $result.Target = if ($q.ContainsKey('target')) { $q['target'] } else { "" }
    $result.IconUrl = if ($q.ContainsKey('icon')) { $q['icon'] } else { "" }
    $result.HeadersText = if ($q.ContainsKey('headers')) { $q['headers'] } else { "" }
    $result.NormalizedScriptHubUrl = $Url -replace '^http://script\.hub/', 'https://script.hub/'

    return [pscustomobject]$result
}

function Get-ExtFromUrlOrName {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $clean = ($Text -split '\?')[0]
    $file = [System.IO.Path]::GetFileName($clean)
    $ext = [System.IO.Path]::GetExtension($file)

    if ([string]::IsNullOrWhiteSpace($ext)) {
        return ""
    }

    return $ext.ToLowerInvariant()
}

function Get-BaseNameFromUrlOrName {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "module"
    }

    $clean = ($Text -split '\?')[0]
    $file = [System.IO.Path]::GetFileName($clean)

    if ([string]::IsNullOrWhiteSpace($file)) {
        return "module"
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $name = $name -replace '[^A-Za-z0-9._-]', '_'

    if ([string]::IsNullOrWhiteSpace($name)) {
        return "module"
    }

    return $name
}

function Guess-TargetByExt {
    param([string]$Ext)

    switch ($Ext.ToLowerInvariant()) {
        ".yaml" { return "egern" }
        ".yml" { return "egern" }
        ".sgmodule" { return "surge" }
        ".plugin" { return "loon" }
        ".lpx" { return "loon" }
        default { return "surge" }
    }
}

function Resolve-OutputExt {
    param(
        [string]$Target,
        [string]$RequestedExt,
        [string]$SourceExt
    )

    $targetLower = $Target.ToLowerInvariant()
    $req = ""
    $src = ""

    if (-not [string]::IsNullOrWhiteSpace($RequestedExt)) {
        $req = $RequestedExt.Trim().ToLowerInvariant()
        if (-not $req.StartsWith(".")) {
            $req = ".$req"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceExt)) {
        $src = $SourceExt.Trim().ToLowerInvariant()
    }

    if ($targetLower -eq "loon") {
        if ($req -eq ".plugin") {
            return ".plugin"
        }
        return ".plugin"
    }

    if ($targetLower -eq "surge") {
        if ($req -eq ".sgmodule") {
            return ".sgmodule"
        }
        return ".sgmodule"
    }

    if ($targetLower -eq "egern") {
        if ($req -eq ".yml") {
            return ".yml"
        }
        return ".yaml"
    }

    if (-not [string]::IsNullOrWhiteSpace($req)) {
        return $req
    }

    if (-not [string]::IsNullOrWhiteSpace($src)) {
        return $src
    }

    return ".sgmodule"
}

function Get-TargetDir {
    param(
        [string]$Repo,
        [string]$Target
    )

    switch ($Target) {
        "egern" { return Join-Path $Repo "egern\modules" }
        "surge" { return Join-Path $Repo "surge\modules" }
        "loon" { return Join-Path $Repo "loon\plugins" }
        "source" { return Join-Path $Repo "incoming\protected-sources" }
        default { return Join-Path $Repo "surge\modules" }
    }
}

function Get-RawUrlForOutput {
    param(
        [string]$GithubRepo,
        [string]$Branch,
        [string]$Target,
        [string]$FileName
    )

    switch ($Target) {
        "egern" { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/egern/modules/$FileName" }
        "surge" { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/surge/modules/$FileName" }
        "loon" { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/loon/plugins/$FileName" }
        "source" { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/incoming/protected-sources/$FileName" }
        default { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/surge/modules/$FileName" }
    }
}

function Resolve-IconUrl {
    param(
        [string]$Repo,
        [string]$GithubRepo,
        [string]$Branch,
        [string]$IconFile,
        [string]$IconUrl,
        [string]$FileNameNoExt
    )

    if (-not [string]::IsNullOrWhiteSpace($IconUrl)) {
        return $IconUrl.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($IconFile)) {
        $icon = $IconFile.Trim()

        if ($icon -match '^https?://') {
            return $icon
        }

        return "https://raw.githubusercontent.com/$GithubRepo/$Branch/icons/$icon"
    }

    $iconsDir = Join-Path $Repo "icons"

    if (Test-Path $iconsDir) {
        $candidate = Get-ChildItem $iconsDir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.BaseName -ieq $FileNameNoExt
        } | Select-Object -First 1

        if ($candidate) {
            return "https://raw.githubusercontent.com/$GithubRepo/$Branch/icons/$($candidate.Name)"
        }
    }

    return ""
}

function Normalize-ModuleText {
    param([string]$Content)

    if ($null -eq $Content) {
        return ""
    }

    $c = $Content -replace "^\uFEFF", ""

    $c = $c -replace '\s+(?=#!(?:name|desc|author|homepage|icon|arguments|argument|raw-url|tg-channel|date|openUrl|tag|system|system_version|loon_version|cron|description)\s*=)', "`r`n"
    $c = $c -replace '\s+(?=\[(Argument|Rule|Rewrite|URL Rewrite|Script|MITM|MitM|Map Local|Header Rewrite|General)\])', "`r`n`r`n"

    return $c.Trim()
}

function Apply-TextModuleMetadata {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Desc,
        [string]$IconUrl,
        [bool]$PreserveMetadata
    )

    $content = Normalize-ModuleText -Content $Content
    $lines = $content -split "`r?`n"

    if ($PreserveMetadata) {
        $out = $lines

        if (-not [string]::IsNullOrWhiteSpace($IconUrl)) {
            $hasIcon = $false

            foreach ($line in $out) {
                if ($line -match '^#!icon\s*=') {
                    $hasIcon = $true
                    break
                }
            }

            if (-not $hasIcon) {
                $insertIndex = 0

                for ($i = 0; $i -lt $out.Count; $i++) {
                    if ($out[$i] -match '^#!') {
                        $insertIndex = $i + 1
                    }
                }

                $before = @()
                $after = @()

                if ($insertIndex -gt 0) {
                    $before = $out[0..($insertIndex - 1)]
                }

                if ($insertIndex -lt $out.Count) {
                    $after = $out[$insertIndex..($out.Count - 1)]
                }

                $out = @($before + "#!icon=$IconUrl" + $after)
            }
        }

        return (($out -join "`r`n").Trim() + "`r`n")
    }

    $bodyLines = $lines | Where-Object {
        $_ -notmatch '^#!(?:name|desc|icon)\s*='
    }

    if ([string]::IsNullOrWhiteSpace($Desc)) {
        $Desc = $Name
    }

    $header = @(
        "#!name=$Name",
        "#!desc=$Desc"
    )

    if (-not [string]::IsNullOrWhiteSpace($IconUrl)) {
        $header += "#!icon=$IconUrl"
    }

    return (($header -join "`r`n") + "`r`n`r`n" + (($bodyLines -join "`r`n").TrimStart()) + "`r`n")
}

function Apply-YamlModuleMetadata {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Desc,
        [string]$IconUrl,
        [bool]$PreserveMetadata
    )

    $c = $Content -replace "^\uFEFF", ""

    if ($PreserveMetadata) {
        if (-not [string]::IsNullOrWhiteSpace($IconUrl) -and $c -notmatch '(?m)^icon\s*:') {
            if ($c -match '(?m)^description\s*:') {
                $c = [regex]::Replace($c, '(?m)^(description\s*:.*)$', "`$1`nicon: $IconUrl", 1)
            } elseif ($c -match '(?m)^name\s*:') {
                $c = [regex]::Replace($c, '(?m)^(name\s*:.*)$', "`$1`nicon: $IconUrl", 1)
            } else {
                $c = "icon: $IconUrl`n$c"
            }
        }

        return $c.TrimEnd() + "`n"
    }

    if ([string]::IsNullOrWhiteSpace($Desc)) {
        $Desc = $Name
    }

    if ($c -match '(?m)^name\s*:') {
        $c = [regex]::Replace($c, '(?m)^name\s*:.*$', "name: $Name", 1)
    } else {
        $c = "name: $Name`n$c"
    }

    if ($c -match '(?m)^description\s*:') {
        $c = [regex]::Replace($c, '(?m)^description\s*:.*$', "description: $Desc", 1)
    } else {
        $c = [regex]::Replace($c, '(?m)^(name\s*:.*)$', "`$1`ndescription: $Desc", 1)
    }

    if (-not [string]::IsNullOrWhiteSpace($IconUrl)) {
        if ($c -match '(?m)^icon\s*:') {
            $c = [regex]::Replace($c, '(?m)^icon\s*:.*$', "icon: $IconUrl", 1)
        } else {
            $c = [regex]::Replace($c, '(?m)^(description\s*:.*)$', "`$1`nicon: $IconUrl", 1)
        }
    }

    return $c.TrimEnd() + "`n"
}

function Apply-ModuleMetadata {
    param(
        [string]$Content,
        [string]$Target,
        [string]$Name,
        [string]$Desc,
        [string]$IconUrl,
        [bool]$PreserveMetadata
    )

    if ($Target -eq "egern") {
        return Apply-YamlModuleMetadata -Content $Content -Name $Name -Desc $Desc -IconUrl $IconUrl -PreserveMetadata:$PreserveMetadata
    }

    return Apply-TextModuleMetadata -Content $Content -Name $Name -Desc $Desc -IconUrl $IconUrl -PreserveMetadata:$PreserveMetadata
}

function Build-Headers {
    param(
        [object]$Entry,
        [string]$ScriptHubHeadersText
    )

    $headers = @{
        "User-Agent" = "ProxyKit-Staticizer/1.0"
        "Accept" = "*/*"
    }

    $queryHeaders = Parse-HeadersText $ScriptHubHeadersText
    $headers = Merge-Headers -Base $headers -Extra $queryHeaders

    $userAgent = Get-PropValue $Entry "UserAgent" ""
    if (-not [string]::IsNullOrWhiteSpace($userAgent)) {
        $headers["User-Agent"] = $userAgent.Trim()
    }

    $referer = Get-PropValue $Entry "Referer" ""
    if (-not [string]::IsNullOrWhiteSpace($referer)) {
        $headers["Referer"] = $referer.Trim()
    }

    $headersText = Get-PropValue $Entry "Headers" ""
    $manualHeaders = Parse-HeadersText $headersText
    $headers = Merge-Headers -Base $headers -Extra $manualHeaders

    return $headers
}

function Invoke-DownloadText {
    param(
        [string]$Url,
        [int]$TimeoutSec,
        [int]$Retry,
        [hashtable]$Headers
    )

    $lastErr = $null

    for ($i = 1; $i -le $Retry; $i++) {
        try {
            Write-Host "下载[$i/$Retry]: $Url" -ForegroundColor DarkGray

            $resp = Invoke-WebRequest `
                -Uri $Url `
                -UseBasicParsing `
                -TimeoutSec $TimeoutSec `
                -Headers $Headers

            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
                return [string]$resp.Content
            }

            $lastErr = "状态码 $($resp.StatusCode)"
        } catch {
            $lastErr = $_.Exception.Message
            Start-Sleep -Seconds ([Math]::Min(3 * $i, 10))
        }
    }

    throw "下载失败：$Url`n原因：$lastErr"
}

function Extract-ModuleUrlsFromConfig {
    param([string]$ConfigText)

    $urls = New-Object System.Collections.Generic.List[string]

    $m = [regex]::Match($ConfigText, '(?ms)^modules:\s*\r?\n(?<body>.*?)(?=^[A-Za-z_][A-Za-z0-9_]*:|\z)')

    if (-not $m.Success) {
        return $urls
    }

    $body = $m.Groups['body'].Value

    foreach ($mm in [regex]::Matches($body, '(?m)^\s*url:\s*(?<url>.+?)\s*$')) {
        $u = $mm.Groups['url'].Value.Trim().Trim('"').Trim("'")

        if ($u) {
            $urls.Add($u)
        }
    }

    return $urls
}

function New-EntryFromUrl {
    param([string]$Url)

    $parsed = Parse-ScriptHubUrl $Url

    if ($parsed.IsScriptHub) {
        $base = Get-BaseNameFromUrlOrName $parsed.OutputName
        $name = $base

        if ($parsed.Query.ContainsKey('n')) {
            $name = $parsed.Query['n']
        }

        return [pscustomobject]@{
            Name = $name
            Desc = ""
            OldUrl = $Url
            SourceUrl = $parsed.SourceUrl
            ScriptHubUrl = $parsed.NormalizedScriptHubUrl
            FileName = $base
            IconFile = ""
            IconUrl = $parsed.IconUrl
            Target = "auto"
            Extension = ""
            Mode = "auto"
            Enabled = "true"
            PreserveMetadata = "false"
            UserAgent = ""
            Referer = ""
            Headers = $parsed.HeadersText
        }
    }

    $base = Get-BaseNameFromUrlOrName $Url

    return [pscustomobject]@{
        Name = $base
        Desc = ""
        OldUrl = $Url
        SourceUrl = Normalize-GitHubRawUrl $Url
        ScriptHubUrl = ""
        FileName = $base
        IconFile = ""
        IconUrl = ""
        Target = "auto"
        Extension = ""
        Mode = "direct"
        Enabled = "true"
        PreserveMetadata = "false"
        UserAgent = ""
        Referer = ""
        Headers = ""
    }
}

function Import-Manifest {
    param([string]$ManifestPath)

    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path $ManifestPath)) {
        return @()
    }

    return Import-Csv $ManifestPath
}

function Staticize-Entry {
    param([object]$Entry)

    $oldUrl = Get-PropValue $Entry "OldUrl" ""
    $sourceUrl = Normalize-GitHubRawUrl (Get-PropValue $Entry "SourceUrl" "")
    $scriptHubUrl = Get-PropValue $Entry "ScriptHubUrl" ""
    $name = Get-PropValue $Entry "Name" ""
    $desc = Get-PropValue $Entry "Desc" ""
    $fileNameNoExt = Get-PropValue $Entry "FileName" ""
    $iconFile = Get-PropValue $Entry "IconFile" ""
    $iconUrlManual = Get-PropValue $Entry "IconUrl" ""
    $target = (Get-PropValue $Entry "Target" "auto").ToLowerInvariant()
    $requestedExt = (Get-PropValue $Entry "Extension" "").ToLowerInvariant()
    $mode = (Get-PropValue $Entry "Mode" "auto").ToLowerInvariant()
    $preserveMetadata = Test-Truthy (Get-PropValue $Entry "PreserveMetadata" "false")

    $parsed = $null
    $scriptHubHeadersText = ""

    if ([string]::IsNullOrWhiteSpace($sourceUrl) -and -not [string]::IsNullOrWhiteSpace($oldUrl)) {
        $parsed = Parse-ScriptHubUrl $oldUrl

        if ($parsed.IsScriptHub) {
            $sourceUrl = $parsed.SourceUrl
            $scriptHubUrl = $parsed.NormalizedScriptHubUrl
            $scriptHubHeadersText = $parsed.HeadersText

            if ([string]::IsNullOrWhiteSpace($iconUrlManual)) {
                $iconUrlManual = $parsed.IconUrl
            }

            if ([string]::IsNullOrWhiteSpace($fileNameNoExt)) {
                $fileNameNoExt = Get-BaseNameFromUrlOrName $parsed.OutputName
            }

            if ([string]::IsNullOrWhiteSpace($name)) {
                if ($parsed.Query.ContainsKey('n')) {
                    $name = $parsed.Query['n']
                }
            }
        } else {
            $sourceUrl = Normalize-GitHubRawUrl $oldUrl
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($oldUrl)) {
        $parsed = Parse-ScriptHubUrl $oldUrl

        if ($parsed.IsScriptHub) {
            $scriptHubHeadersText = $parsed.HeadersText

            if ([string]::IsNullOrWhiteSpace($scriptHubUrl)) {
                $scriptHubUrl = $parsed.NormalizedScriptHubUrl
            }

            if ([string]::IsNullOrWhiteSpace($iconUrlManual)) {
                $iconUrlManual = $parsed.IconUrl
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($fileNameNoExt)) {
        $fileNameNoExt = Get-BaseNameFromUrlOrName $sourceUrl
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $fileNameNoExt
    }

    if ([string]::IsNullOrWhiteSpace($desc)) {
        $desc = $name
    }

    $sourceExt = Get-ExtFromUrlOrName $sourceUrl
    $directable = @(".lpx", ".plugin", ".sgmodule", ".yaml", ".yml") -contains $sourceExt

    if ($target -eq "auto" -or [string]::IsNullOrWhiteSpace($target)) {
        if ($mode -eq "source") {
            $target = "source"
        } elseif ($directable -and -not $ForceScriptHub -and $mode -ne "scripthub") {
            $target = Guess-TargetByExt $sourceExt
        } else {
            $parsed2 = if (-not [string]::IsNullOrWhiteSpace($oldUrl)) { Parse-ScriptHubUrl $oldUrl } else { $null }

            if ($parsed2 -and $parsed2.IsScriptHub -and $parsed2.Target -match 'loon') {
                $target = "loon"
            } elseif ($parsed2 -and $parsed2.IsScriptHub -and $parsed2.Target -match 'surge') {
                $target = "surge"
            } elseif ($parsed2 -and $parsed2.IsScriptHub -and $parsed2.Target -match 'egern') {
                $target = "egern"
            } else {
                $target = Guess-TargetByExt $sourceExt
            }
        }
    }

    $ext = Resolve-OutputExt -Target $target -RequestedExt $requestedExt -SourceExt $sourceExt

    if ($target -eq "source") {
        if ([string]::IsNullOrWhiteSpace($sourceExt)) {
            $ext = ".txt"
        } else {
            $ext = $sourceExt
        }
    }

    $downloadUrl = $sourceUrl

    if ($ForceScriptHub -or ($mode -eq "scripthub") -or ((-not $directable) -and -not [string]::IsNullOrWhiteSpace($scriptHubUrl) -and $mode -ne "source")) {
        $downloadUrl = $scriptHubUrl
    }

    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        throw "缺少可下载 URL：$name"
    }

    $iconUrl = Resolve-IconUrl `
        -Repo $Repo `
        -GithubRepo $GithubRepo `
        -Branch $Branch `
        -IconFile $iconFile `
        -IconUrl $iconUrlManual `
        -FileNameNoExt $fileNameNoExt

    $headers = Build-Headers -Entry $Entry -ScriptHubHeadersText $scriptHubHeadersText

    $content = Invoke-DownloadText `
        -Url $downloadUrl `
        -TimeoutSec $TimeoutSec `
        -Retry $Retry `
        -Headers $headers

    if ($target -ne "source") {
        $content = Apply-ModuleMetadata `
            -Content $content `
            -Target $target `
            -Name $name `
            -Desc $desc `
            -IconUrl $iconUrl `
            -PreserveMetadata:$preserveMetadata
    }

    $targetDir = Get-TargetDir -Repo $Repo -Target $target
    Ensure-Dir $targetDir

    $outFile = "$fileNameNoExt$ext"
    $outPath = Join-Path $targetDir $outFile

    Write-Utf8NoBom -Path $outPath -Content $content

    $raw = Get-RawUrlForOutput `
        -GithubRepo $GithubRepo `
        -Branch $Branch `
        -Target $target `
        -FileName $outFile

    return [pscustomobject]@{
        Name = $name
        OldUrl = $oldUrl
        SourceUrl = $sourceUrl
        DownloadUrl = $downloadUrl
        OutputPath = $outPath
        RawUrl = $raw
        Target = $target
        IconUrl = $iconUrl
        PreserveMetadata = $preserveMetadata
        Status = "OK"
        Error = ""
    }
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $candidate1 = Join-Path $Repo "egern.yaml"
    $candidate2 = Join-Path $Repo "config.yaml"

    if (Test-Path $candidate1) {
        $ConfigPath = $candidate1
    } elseif (Test-Path $candidate2) {
        $ConfigPath = $candidate2
    }
}

Ensure-Dir (Join-Path $Repo "loon\plugins")
Ensure-Dir (Join-Path $Repo "surge\modules")
Ensure-Dir (Join-Path $Repo "egern\modules")
Ensure-Dir (Join-Path $Repo "incoming\protected-sources")
Ensure-Dir (Join-Path $Repo "scripts")

$configText = ""
$configUrls = @()

if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path $ConfigPath)) {
    $configText = Get-Content $ConfigPath -Raw -Encoding UTF8

    if (-not $SkipConfigScan) {
        $configUrls = Extract-ModuleUrlsFromConfig $configText
    }
}

$entries = New-Object System.Collections.Generic.List[object]

foreach ($u in $configUrls) {
    if ($u -match 'script\.hub/file/_start_') {
        $entries.Add((New-EntryFromUrl $u))
    }
}

foreach ($m in (Import-Manifest $ManifestPath)) {
    $entries.Add($m)
}

if ($entries.Count -eq 0) {
    Write-Host "没有需要静态化的条目。请提供包含 ScriptHub 链接的 ConfigPath，或提供 ManifestPath。" -ForegroundColor Yellow
    exit 0
}

$results = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[object]
$generatedPaths = New-Object System.Collections.Generic.List[string]

foreach ($entry in $entries) {
    try {
        $r = Staticize-Entry $entry
        $results.Add($r)
        $generatedPaths.Add($r.OutputPath)

        Write-Host "完成：$($r.Name) -> $($r.RawUrl)" -ForegroundColor Green

        if (-not [string]::IsNullOrWhiteSpace($configText) -and -not [string]::IsNullOrWhiteSpace($r.OldUrl)) {
            $configText = $configText.Replace($r.OldUrl, $r.RawUrl)
        }
    } catch {
        $msg = $_.Exception.Message
        Write-Host "失败：$($entry.Name) $msg" -ForegroundColor Red

        $failures.Add([pscustomobject]@{
            Name = Get-PropValue $entry "Name" ""
            OldUrl = Get-PropValue $entry "OldUrl" ""
            SourceUrl = Get-PropValue $entry "SourceUrl" ""
            Error = $msg
        })
    }
}

$logDir = Join-Path $Repo "scripts\logs"
Ensure-Dir $logDir

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$okLog = Join-Path $logDir "staticize-ok-$stamp.csv"
$failLog = Join-Path $logDir "staticize-failed-$stamp.csv"

$results | Export-Csv $okLog -NoTypeInformation -Encoding UTF8
$failures | Export-Csv $failLog -NoTypeInformation -Encoding UTF8

if (-not [string]::IsNullOrWhiteSpace($configText) -and -not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $outConfig = if ($OverwriteConfig) {
        $ConfigPath
    } else {
        [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($ConfigPath),
            ([System.IO.Path]::GetFileNameWithoutExtension($ConfigPath) + ".staticized" + [System.IO.Path]::GetExtension($ConfigPath))
        )
    }

    Write-Utf8NoBom -Path $outConfig -Content $configText
    Write-Host "配置已输出：$outConfig" -ForegroundColor Cyan
}

if ($GitPush) {
    Set-Location $Repo

    $uniquePaths = $generatedPaths | Sort-Object -Unique

    foreach ($p in $uniquePaths) {
        if (Test-Path $p) {
            git add $p
        }
    }

    if (Test-Path $okLog) {
        git add $okLog
    }

    if (Test-Path $failLog) {
        git add $failLog
    }

    $status = git status --porcelain

    if ($status) {
        git commit -m $CommitMessage
        git push
        Write-Host "GitHub 已推送。" -ForegroundColor Green
    } else {
        Write-Host "没有 Git 变更，无需推送。" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "静态化完成。成功 $($results.Count) 项，失败 $($failures.Count) 项。" -ForegroundColor Cyan

if ($failures.Count -gt 0) {
    Write-Host "失败清单已写入：$failLog" -ForegroundColor Yellow
    Write-Host "失败项通常是 JS/QX 资源需要 ScriptHub 转换环境，或源站超时、反爬、证书失败。" -ForegroundColor Yellow
}