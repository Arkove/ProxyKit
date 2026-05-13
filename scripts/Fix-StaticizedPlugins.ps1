$Repo = "D:\onedrive\Desktop\Code\ProxyKit"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$Modules = @(
  @{
    File = "loon\plugins\TencentVideo.plugin"
    Name = "腾讯视频去广告"
    Icon = "https://raw.githubusercontent.com/HotKids/Rules/master/Quantumult/X/Images/Task/tencentvideo.png"
  },
  @{
    File = "loon\plugins\iQIYI.plugin"
    Name = "爱奇艺去广告"
    Icon = "https://raw.githubusercontent.com/luestr/IconResource/main/App_icon/120px/iQiYi_Video.png"
  },
  @{
    File = "loon\plugins\Apple.plugin"
    Name = "Apple 服务增强"
    Icon = "https://raw.githubusercontent.com/lige47/QuanX-icon-rule/main/icon/03CNSoft/apple.png"
  },
  @{
    File = "loon\plugins\McDonalds.plugin"
    Name = "麦当劳增强"
    Icon = "https://raw.githubusercontent.com/lige47/QuanX-icon-rule/main/icon/03CNSoft/mcdonalds.png"
  },
  @{
    File = "loon\plugins\MeituanPowerBank.plugin"
    Name = "美团充电宝增强"
    Icon = "https://raw.githubusercontent.com/Toperlock/Quantumult/main/icon/meituan.png"
  },
  @{
    File = "loon\plugins\Meituan-MeituanWaimai.plugin"
    Name = "美团与美团外卖增强"
    Icon = "https://raw.githubusercontent.com/luestr/IconResource/main/App_icon/120px/MeiTuanItakeaway.png"
  },
  @{
    File = "loon\plugins\Mijia.plugin"
    Name = "米家增强"
    Icon = "https://raw.githubusercontent.com/luestr/IconResource/main/App_icon/120px/MiHome.png"
  },
  @{
    File = "loon\plugins\QiMai.plugin"
    Name = "七麦数据增强"
    Icon = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/qimai.png"
  },
  @{
    File = "loon\plugins\ZhangShangDaoJuCheng.plugin"
    Name = "掌上道聚城增强"
    Icon = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/daojuchen.png"
  },
  @{
    File = "loon\plugins\ZhangShangLOL.plugin"
    Name = "掌上英雄联盟增强"
    Icon = "https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/zhangmeng.png"
  },
  @{
    File = "loon\plugins\ZhangTongJiaYuan.plugin"
    Name = "掌通家园增强"
    Icon = ""
  }
)

foreach ($Module in $Modules) {
  $FullPath = Join-Path $Repo $Module.File

  if (-not (Test-Path $FullPath)) {
    Write-Host "跳过，不存在：$FullPath" -ForegroundColor Yellow
    continue
  }

  $Content = [System.IO.File]::ReadAllText($FullPath, [System.Text.Encoding]::UTF8)

  $Content = $Content -replace '\s+(?=#!(?:name|desc|author|homepage|icon|arguments|argument|raw-url|tg-channel|date)=)', "`r`n"
  $Content = $Content -replace '\s+(?=\[(Argument|Rule|Rewrite|Script|MITM)\])', "`r`n`r`n"

  $Lines = $Content -split "`r?`n"
  $BodyLines = $Lines | Where-Object { $_ -notmatch '^#!' }
  $Body = ($BodyLines -join "`r`n").TrimStart()

  if ([string]::IsNullOrWhiteSpace($Module.Icon)) {
    $Header = "#!name=$($Module.Name)`r`n#!desc=$($Module.Name)`r`n"
  } else {
    $Header = "#!name=$($Module.Name)`r`n#!desc=$($Module.Name)`r`n#!icon=$($Module.Icon)`r`n"
  }

  [System.IO.File]::WriteAllText($FullPath, $Header + "`r`n" + $Body, $Utf8NoBom)
  Write-Host "已修复：$($Module.Name)" -ForegroundColor Green
}