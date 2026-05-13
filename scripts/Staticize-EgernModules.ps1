<#
Staticize-EgernModules.ps1
把 Egern 配置中的 ScriptHub 动态转译链接静态化到自己的 ProxyKit 仓库，并自动写入图标、替换配置、git commit/push。

核心逻辑：
1. 从 Egern 配置的 modules: 区域提取 url。
2. 对 script.hub/file/_start_/.../_end_/... 链接：
   - 若源文件本身已是 .lpx/.plugin/.sgmodule/.yaml/.yml，则直接镜像源文件，不再动态转译。
   - 若源文件是 .js/.conf 等需要转换的资源，则尝试下载 ScriptHub 转译后的结果并静态保存。
3. 对 manifest 中手动指定的资源，也执行同样的静态化。
4. 自动注入 #!name / #!desc / #!icon 或 YAML 顶层 icon。
5. 将配置中的旧 URL 替换为自己的 GitHub Raw 静态 URL。
6. 可选 git add / commit / push。
#>

param(
    [string]$Repo = "D:\onedrive\Desktop\Code\ProxyKit",
    [string]$ConfigPath,
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
try { chcp 65001 > $null } catch {}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}

function Normalize-GitHubRawUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
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
    if ($null -eq $Text) { return "" }
    return [System.Uri]::UnescapeDataString($Text.Replace('+',' '))
}

function Parse-Query {
    param([string]$Query)
    $dict = @{}
    if ([string]::IsNullOrWhiteSpace($Query)) { return $dict }
    foreach ($pair in $Query.TrimStart('?').Split('&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $kv = $pair.Split('=',2)
        $key = UrlDecodeSafe $kv[0]
        $val = if ($kv.Count -gt 1) { UrlDecodeSafe $kv[1] } else { "" }
        $dict[$key] = $val
    }
    return $dict
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
    $schemeFixed = $Url -replace '^http://script\.hub/', 'https://script.hub/'
    $result.NormalizedScriptHubUrl = $schemeFixed
    return [pscustomobject]$result
}

function Get-ExtFromUrlOrName {
    param([string]$Text)
    $clean = ($Text -split '\?')[0]
    $file = [System.IO.Path]::GetFileName($clean)
    $ext = [System.IO.Path]::GetExtension($file)
    return $ext.ToLowerInvariant()
}

function Get-BaseNameFromUrlOrName {
    param([string]$Text)
    $clean = ($Text -split '\?')[0]
    $file = [System.IO.Path]::GetFileName($clean)
    if ([string]::IsNullOrWhiteSpace($file)) { return "module" }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
    $name = $name -replace '[^A-Za-z0-9._-]', '_'
    if ([string]::IsNullOrWhiteSpace($name)) { return "module" }
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

function Guess-ExtByTarget {
    param([string]$Target, [string]$FallbackExt)
    if (-not [string]::IsNullOrWhiteSpace($FallbackExt) -and $FallbackExt -match '^\.') { return $FallbackExt.ToLowerInvariant() }
    switch ($Target) {
        "egern" { return ".yaml" }
        "surge" { return ".sgmodule" }
        "loon" { return ".plugin" }
        default { return ".sgmodule" }
    }
}

function Get-TargetDir {
    param([string]$Repo, [string]$Target)
    switch ($Target) {
        "egern" { return Join-Path $Repo "egern\modules" }
        "surge" { return Join-Path $Repo "surge\modules" }
        "loon" { return Join-Path $Repo "loon\plugins" }
        default { return Join-Path $Repo "surge\modules" }
    }
}

function Get-RawUrlForOutput {
    param([string]$GithubRepo, [string]$Branch, [string]$Target, [string]$FileName)
    switch ($Target) {
        "egern" { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/egern/modules/$FileName" }
        "surge" { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/surge/modules/$FileName" }
        "loon" { return "https://raw.githubusercontent.com/$GithubRepo/$Branch/loon/plugins/$FileName" }
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
    if (-not [string]::IsNullOrWhiteSpace($IconUrl)) { return $IconUrl.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($IconFile)) {
        return "https://raw.githubusercontent.com/$GithubRepo/$Branch/icons/$IconFile"
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

function Invoke-DownloadText {
    param([string]$Url, [int]$TimeoutSec, [int]$Retry)
    $lastErr = $null
    for ($i = 1; $i -le $Retry; $i++) {
        try {
            Write-Host "下载[$i/$Retry]: $Url" -ForegroundColor DarkGray
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = 'ProxyKit-Staticizer/1.0' }
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

function Set-HeaderLine {
    param([string]$Content, [string]$Key, [string]$Value)
    $pattern = "(?m)^#!$([regex]::Escape($Key))=.*\r?\n?"
    $Content = [regex]::Replace($Content, $pattern, "")
    return "#!$Key=$Value`n$Content"
}

function Inject-ModuleMeta {
    param([string]$Content, [string]$Target, [string]$Name, [string]$IconUrl)
    $c = $Content -replace "^\uFEFF", ""
    if ($Target -eq "egern") {
        $lines = @()
        if ($c -match '(?m)^name\s*:') {
            $c = [regex]::Replace($c, '(?m)^name\s*:.*$', "name: $Name", 1)
        } else { $lines += "name: $Name" }
        if ($c -match '(?m)^description\s*:') {
            $c = [regex]::Replace($c, '(?m)^description\s*:.*$', "description: $Name", 1)
        } else { $lines += "description: $Name" }
        if (-not [string]::IsNullOrWhiteSpace($IconUrl)) {
            if ($c -match '(?m)^icon\s*:') {
                $c = [regex]::Replace($c, '(?m)^icon\s*:.*$', "icon: $IconUrl", 1)
            } else { $lines += "icon: $IconUrl" }
        }
        if ($lines.Count -gt 0) { $c = ($lines -join "`n") + "`n" + $c }
        return $c.TrimEnd() + "`n"
    }
    $c = Set-HeaderLine $c "name" $Name
    $c = Set-HeaderLine $c "desc" $Name
    if (-not [string]::IsNullOrWhiteSpace($IconUrl)) {
        $c = Set-HeaderLine $c "icon" $IconUrl
    }
    return $c.TrimEnd() + "`n"
}

function Extract-ModuleUrlsFromConfig {
    param([string]$ConfigText)
    $urls = New-Object System.Collections.Generic.List[string]
    $m = [regex]::Match($ConfigText, '(?ms)^modules:\s*\r?\n(?<body>.*?)(?=^[A-Za-z_][A-Za-z0-9_]*:|\z)')
    if (-not $m.Success) { return $urls }
    $body = $m.Groups['body'].Value
    foreach ($mm in [regex]::Matches($body, '(?m)^\s*url:\s*(?<url>.+?)\s*$')) {
        $u = $mm.Groups['url'].Value.Trim().Trim('"').Trim("'")
        if ($u) { $urls.Add($u) }
    }
    return $urls
}

function New-EntryFromUrl {
    param([string]$Url)
    $parsed = Parse-ScriptHubUrl $Url
    if ($parsed.IsScriptHub) {
        $base = Get-BaseNameFromUrlOrName $parsed.OutputName
        $srcExt = Get-ExtFromUrlOrName $parsed.SourceUrl
        $outExt = Get-ExtFromUrlOrName $parsed.OutputName
        $name = $base
        if ($parsed.Query.ContainsKey('n')) { $name = $parsed.Query['n'] }
        return [pscustomobject]@{
            Name = $name
            OldUrl = $Url
            SourceUrl = $parsed.SourceUrl
            ScriptHubUrl = $parsed.NormalizedScriptHubUrl
            FileName = $base
            IconFile = ""
            IconUrl = $parsed.IconUrl
            Target = "auto"
            Extension = $outExt
            Mode = "auto"
            Enabled = "true"
        }
    } else {
        $base = Get-BaseNameFromUrlOrName $Url
        $ext = Get-ExtFromUrlOrName $Url
        return [pscustomobject]@{
            Name = $base
            OldUrl = $Url
            SourceUrl = Normalize-GitHubRawUrl $Url
            ScriptHubUrl = ""
            FileName = $base
            IconFile = ""
            IconUrl = ""
            Target = "auto"
            Extension = $ext
            Mode = "direct"
            Enabled = "true"
        }
    }
}

function Import-Manifest {
    param([string]$ManifestPath)
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path $ManifestPath)) { return @() }
    return Import-Csv $ManifestPath
}

function Staticize-Entry {
    param($Entry)
    $oldUrl = [string]$Entry.OldUrl
    $sourceUrl = Normalize-GitHubRawUrl ([string]$Entry.SourceUrl)
    $scriptHubUrl = [string]$Entry.ScriptHubUrl
    $name = [string]$Entry.Name
    $fileNameNoExt = [string]$Entry.FileName
    $iconFile = [string]$Entry.IconFile
    $iconUrlManual = [string]$Entry.IconUrl
    $target = ([string]$Entry.Target).ToLowerInvariant()
    $ext = ([string]$Entry.Extension).ToLowerInvariant()
    $mode = ([string]$Entry.Mode).ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($sourceUrl) -and -not [string]::IsNullOrWhiteSpace($oldUrl)) {
        $parsed = Parse-ScriptHubUrl $oldUrl
        if ($parsed.IsScriptHub) {
            $sourceUrl = $parsed.SourceUrl
            $scriptHubUrl = $parsed.NormalizedScriptHubUrl
            if ([string]::IsNullOrWhiteSpace($iconUrlManual)) { $iconUrlManual = $parsed.IconUrl }
            if ([string]::IsNullOrWhiteSpace($ext)) { $ext = Get-ExtFromUrlOrName $parsed.OutputName }
            if ([string]::IsNullOrWhiteSpace($fileNameNoExt)) { $fileNameNoExt = Get-BaseNameFromUrlOrName $parsed.OutputName }
        } else {
            $sourceUrl = Normalize-GitHubRawUrl $oldUrl
        }
    }

    if ([string]::IsNullOrWhiteSpace($fileNameNoExt)) { $fileNameNoExt = Get-BaseNameFromUrlOrName $sourceUrl }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $fileNameNoExt }

    $srcExt = Get-ExtFromUrlOrName $sourceUrl
    $directable = @('.lpx','.plugin','.sgmodule','.yaml','.yml') -contains $srcExt

    $downloadUrl = $sourceUrl
    if ($ForceScriptHub -or ($mode -eq 'scripthub') -or ((-not $directable) -and -not [string]::IsNullOrWhiteSpace($scriptHubUrl))) {
        $downloadUrl = $scriptHubUrl
    }

    if ($target -eq "auto" -or [string]::IsNullOrWhiteSpace($target)) {
        if ($directable -and -not $ForceScriptHub -and $mode -ne 'scripthub') {
            $target = Guess-TargetByExt $srcExt
            if ([string]::IsNullOrWhiteSpace($ext)) { $ext = $srcExt }
        } else {
            $parsed2 = if (-not [string]::IsNullOrWhiteSpace($oldUrl)) { Parse-ScriptHubUrl $oldUrl } else { $null }
            if ($parsed2 -and $parsed2.IsScriptHub -and $parsed2.Target -match 'loon') { $target = 'loon' }
            elseif ($parsed2 -and $parsed2.IsScriptHub -and $parsed2.Target -match 'surge') { $target = 'surge' }
            elseif ($parsed2 -and $parsed2.IsScriptHub -and $parsed2.Target -match 'egern') { $target = 'egern' }
            else { $target = Guess-TargetByExt $srcExt }
        }
    }
    $ext = Guess-ExtByTarget $target $ext

    $iconUrl = Resolve-IconUrl -Repo $Repo -GithubRepo $GithubRepo -Branch $Branch -IconFile $iconFile -IconUrl $iconUrlManual -FileNameNoExt $fileNameNoExt
    $content = Invoke-DownloadText -Url $downloadUrl -TimeoutSec $TimeoutSec -Retry $Retry
    $content = Inject-ModuleMeta -Content $content -Target $target -Name $name -IconUrl $iconUrl

    $targetDir = Get-TargetDir -Repo $Repo -Target $target
    Ensure-Dir $targetDir
    $outFile = "$fileNameNoExt$ext"
    $outPath = Join-Path $targetDir $outFile
    Write-Utf8NoBom -Path $outPath -Content $content
    $raw = Get-RawUrlForOutput -GithubRepo $GithubRepo -Branch $Branch -Target $target -FileName $outFile

    return [pscustomobject]@{
        Name = $name
        OldUrl = $oldUrl
        SourceUrl = $sourceUrl
        DownloadUrl = $downloadUrl
        OutputPath = $outPath
        RawUrl = $raw
        Target = $target
        IconUrl = $iconUrl
        Status = "OK"
        Error = ""
    }
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $candidate1 = Join-Path $Repo "egern.yaml"
    $candidate2 = Join-Path $Repo "config.yaml"
    if (Test-Path $candidate1) { $ConfigPath = $candidate1 }
    elseif (Test-Path $candidate2) { $ConfigPath = $candidate2 }
}

Ensure-Dir (Join-Path $Repo "loon\plugins")
Ensure-Dir (Join-Path $Repo "surge\modules")
Ensure-Dir (Join-Path $Repo "egern\modules")
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

foreach ($entry in $entries) {
    try {
        $r = Staticize-Entry $entry
        $results.Add($r)
        Write-Host "完成：$($r.Name) -> $($r.RawUrl)" -ForegroundColor Green
        if (-not [string]::IsNullOrWhiteSpace($configText) -and -not [string]::IsNullOrWhiteSpace($r.OldUrl)) {
            $configText = $configText.Replace($r.OldUrl, $r.RawUrl)
        }
    } catch {
        $msg = $_.Exception.Message
        Write-Host "失败：$($entry.Name) $msg" -ForegroundColor Red
        $failures.Add([pscustomobject]@{
            Name = [string]$entry.Name
            OldUrl = [string]$entry.OldUrl
            SourceUrl = [string]$entry.SourceUrl
            Error = $msg
        })
    }
}

$logDir = Join-Path $Repo "scripts\logs"
Ensure-Dir $logDir
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$results | Export-Csv (Join-Path $logDir "staticize-ok-$stamp.csv") -NoTypeInformation -Encoding UTF8
$failures | Export-Csv (Join-Path $logDir "staticize-failed-$stamp.csv") -NoTypeInformation -Encoding UTF8

if (-not [string]::IsNullOrWhiteSpace($configText) -and -not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $outConfig = if ($OverwriteConfig) { $ConfigPath } else { [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($ConfigPath), ([System.IO.Path]::GetFileNameWithoutExtension($ConfigPath) + ".staticized" + [System.IO.Path]::GetExtension($ConfigPath))) }
    Write-Utf8NoBom -Path $outConfig -Content $configText
    Write-Host "配置已输出：$outConfig" -ForegroundColor Cyan
}

if ($GitPush) {
    Set-Location $Repo
    git add .
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
    Write-Host "失败清单已写入 scripts\logs。失败项通常是 JS/QX 资源需要 ScriptHub 转换环境，或源站超时。" -ForegroundColor Yellow
}
