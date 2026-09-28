@echo off
setlocal enabledelayedexpansion
title ImgBed - deploy the Worker (script + static assets)
cd /d "%~dp0"

set "HOST=https://imgbed.9ll.uk"
set "TOML=deploy\worker\wrangler.toml"
set "DEPS=node_modules\@sentry\tracing"
set "DRY="
if /i "%~1"=="--dry" set "DRY=--dry-run"

echo ============================================================
echo   CloudFlare ImgBed - Worker deploy helper
echo   repo   : %CD%
echo   site   : %HOST%
echo   worker : cloudflare-imgbed
echo ============================================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [X] Node.js not found. Install Node.js 22 or newer first.
  echo.
  pause
  exit /b 1
)

if exist "%DEPS%" goto :step2

echo [1/7] installing worker dependencies - a few minutes, please wait ...
call npm install --no-audit --no-fund --workspace=@cloudflare-imgbed/common --workspace=@cloudflare-imgbed/worker
if errorlevel 1 (
  echo [X] npm install failed. Check network / proxy, then retry.
  pause
  exit /b 1
)
goto :step2

:step2
echo [1/7] dependencies present
if not "%DRY%"=="" goto :step4

echo.
echo [2/7] checking Cloudflare login ...
call npx --yes wrangler@4 whoami
if errorlevel 1 (
  echo.
  echo [X] Not logged in. Run this once in this folder, finish the
  echo     browser prompt, then start this helper again:
  echo.
  echo         npx wrangler@4 login
  echo.
  pause
  exit /b 1
)

echo.
echo [3/7] KV namespaces - copy the "id" of the one bound as img_url
echo       migrated to D1? use:  npx wrangler@4 d1 list
call npx --yes wrangler@4 kv namespace list
goto :step4

:step4
echo.
echo [4/7] Fill in the bindings in this file:
echo         %CD%\%TOML%
echo.
echo       Uncomment and complete, keeping binding names EXACTLY:
echo.
echo         [[kv_namespaces]]
echo         binding = "img_url"
echo         id = "paste-your-kv-id"
echo.
echo         [[r2_buckets]]
echo         binding = "img_r2"
echo         bucket_name = "your-bucket"
echo.
echo       Only the KV block is mandatory.
echo       If the deploy complains about the IMAGES binding, delete
echo       the [images] block (2 lines) and run this helper again.
echo.
if not "%DRY%"=="" goto :step5
echo       Press any key once the file is saved ...
pause >nul
goto :step5

:step5
echo.
echo [5/7] generating deploy\worker\index.js from functions\ ...
node deploy\worker\generate-routes.js
if errorlevel 1 (
  echo [X] generate-routes failed.
  pause
  exit /b 1
)

echo.
echo [6/7] deploying the Worker %DRY% ...
call npx --yes wrangler@4 deploy --config "%TOML%" %DRY%
if errorlevel 1 (
  echo.
  echo [X] deploy failed - read the error above.
  echo     could not resolve @sentry/*  -^> rerun step 1 (npm install)
  echo     IMAGES not enabled           -^> remove the [images] block
  echo     name mismatch                -^> name must be cloudflare-imgbed
  pause
  exit /b 1
)

echo.
echo [7/7] verifying the API ...
if not "%DRY%"=="" (
  echo       --dry mode: nothing was uploaded, skipping the probe
  pause
  exit /b 0
)
curl -s --max-time 20 "%HOST%/api/auth/sessionCheck"
echo.
echo.
echo ============================================================
echo   expected:
echo     {"valid":false,"adminRequired":...,"userRequired":...}
echo.
echo   still 404 -^> something still overwrites this Worker:
echo                Cloudflare dashboard -^> Workers and Pages -^>
echo                cloudflare-imgbed -^> Settings -^> Builds -^>
echo                Disconnect the Git connection.
echo   userRequired:true -^> an upload password exists; reset it
echo                with /api/auth/resetAuth?key=$RESET_KEY
echo ============================================================
echo.
pause
exit /b 0
