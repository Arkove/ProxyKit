@echo off
chcp 65001 >nul
set REPO=D:\onedrive\Desktop\Code\ProxyKit
set CONFIG=%REPO%\egern.yaml
powershell -ExecutionPolicy Bypass -File "%REPO%\scripts\Staticize-EgernModules.ps1" -Repo "%REPO%" -ConfigPath "%CONFIG%" -ManifestPath "%REPO%\scripts\staticize-modules.example.csv" -OverwriteConfig -GitPush
pause
