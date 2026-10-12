@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem Keep the existing batch CALL parser and its argument semantics. This child
rem is started only while its parent holds the launch-generation gate.
call "%NODE_EXE%" .\dist\index.js %SERVER_ARGS%
exit /b %errorlevel%
