@echo off
start "ScaleWorld Publish PixelStreaming Target Ref" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-target-ref.ps1" %*
