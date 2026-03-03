@echo off
setlocal

set ROOT=C:\PixelStreaming\PixelStreaming\SignallingWebServer
cd /d "%ROOT%\platform_scripts\cmd"

call start.bat -- ^
  --peer_options_player_file="%ROOT%\peer_options.player.json" ^
  --peer_options_streamer_file="%ROOT%\peer_options.streamer.json"
