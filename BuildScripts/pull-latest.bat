@echo off
setlocal

cd /d "%~dp0.."

git rev-parse --is-inside-work-tree >nul 2>nul
if errorlevel 1 (
  echo ERROR: This script must run from a git repository.
  exit /b 1
)

for /f %%I in ('git rev-parse --abbrev-ref HEAD') do set "BRANCH=%%I"
if not defined BRANCH (
  echo ERROR: Failed to detect current branch.
  exit /b 1
)

echo Fetching origin...
git fetch origin
if errorlevel 1 (
  echo ERROR: git fetch failed.
  exit /b 1
)

echo Pulling origin/%BRANCH% with fast-forward only...
git pull --ff-only origin %BRANCH%
if errorlevel 1 (
  echo ERROR: git pull failed. Resolve local branch divergence or local changes, then retry.
  exit /b 1
)

echo Done.
exit /b 0
