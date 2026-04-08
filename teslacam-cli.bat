@echo off
setlocal
set SCRIPT_DIR=%~dp0
if exist "%SystemRoot%\py.exe" (
  py -3 "%SCRIPT_DIR%teslacam.py" %*
  exit /b %ERRORLEVEL%
)
python "%SCRIPT_DIR%teslacam.py" %*
exit /b %ERRORLEVEL%
