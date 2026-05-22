@echo off
start "ScaleWorld Publish PixelStreaming Runtime Artifact" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish-runtime-artifact.ps1" %*
