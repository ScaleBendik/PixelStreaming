@echo off
start "ScaleWorld Prod PixelStreaming Target Ref" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-prod-git-target-ref.ps1" %*
