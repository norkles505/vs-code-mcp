@echo off
REM install.bat
REM Doble clic aqui para instalar todo el bridge vscode-mcp automaticamente:
REM extension de VS Code (compilada e instalada de forma permanente),
REM servidor MCP en Python, y registro en claude_desktop_config.json.
REM
REM Este .bat existe solo para poder ejecutar install.ps1 sin toparse con
REM el error de "la ejecucion de scripts esta deshabilitada en este sistema".

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
