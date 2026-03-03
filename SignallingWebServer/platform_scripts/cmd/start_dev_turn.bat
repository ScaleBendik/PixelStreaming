@echo off
setlocal

set ROOT=C:\PixelStreaming\PixelStreaming\SignallingWebServer
cd /d "%ROOT%\platform_scripts\cmd"

call start.bat -- --peer_options_file="%ROOT%\peer_options.dev_turn.json"
