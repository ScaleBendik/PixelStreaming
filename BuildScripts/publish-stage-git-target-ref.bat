@echo off
start "ScaleWorld Stage PixelStreaming Target Ref" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-stage-git-target-ref.ps1" %*
