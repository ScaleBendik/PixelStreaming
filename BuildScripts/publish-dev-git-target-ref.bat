@echo off
start "ScaleWorld Dev PixelStreaming Target Ref" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-dev-git-target-ref.ps1" %*
