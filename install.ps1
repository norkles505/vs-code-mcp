# install.ps1
# Instala automáticamente el bridge vscode-mcp completo:
#   1. Dependencias + compilación de la extensión de VS Code
#   2. Empaquetado (.vsix) e instalación permanente en VS Code
#   3. Instalación del servidor MCP en Python
#   4. Registro (o actualización) del servidor en claude_desktop_config.json
#
# Este script se corre siempre vía install.bat (que evita el problema de
# la política de ejecución de PowerShell). No hace falta ejecutarlo a mano.

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "    OK: $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "    AVISO: $msg" -ForegroundColor Yellow
}

# Carpeta raíz del proyecto = donde vive este script
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$extensionDir = Join-Path $root "extension"
$serverDir = Join-Path $root "server"

# ---------------------------------------------------------------------------
# 0. Verificar requisitos
# ---------------------------------------------------------------------------
Write-Step "Verificando requisitos (Node.js, npm, VS Code, Python)"

function Test-Command($name) {
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

if (-not (Test-Command "node")) {
    Write-Host "ERROR: No se encontró Node.js. Instálalo desde https://nodejs.org y vuelve a correr este script." -ForegroundColor Red
    exit 1
}
if (-not (Test-Command "npm")) {
    Write-Host "ERROR: No se encontró npm (debería venir con Node.js)." -ForegroundColor Red
    exit 1
}
if (-not (Test-Command "code")) {
    Write-Host "ERROR: No se encontró el comando 'code'. Abre VS Code, presiona Ctrl+Shift+P, busca 'Shell Command: Install code command in PATH' y ejecútalo. Luego vuelve a correr este script." -ForegroundColor Red
    exit 1
}
if (-not (Test-Command "pip")) {
    Write-Host "ERROR: No se encontró Python/pip. Instala Python desde https://python.org (marca 'Add to PATH' durante la instalación)." -ForegroundColor Red
    exit 1
}
Write-Ok "Node, npm, code y pip disponibles"

# ---------------------------------------------------------------------------
# 1. Instalar dependencias y compilar la extensión
# ---------------------------------------------------------------------------
Write-Step "Instalando dependencias de la extensión (npm install)"
Push-Location $extensionDir
npm install
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR en npm install" -ForegroundColor Red; exit 1 }
Write-Ok "Dependencias instaladas"

Write-Step "Compilando la extensión (npm run compile)"
npm run compile
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR al compilar" -ForegroundColor Red; exit 1 }
Write-Ok "Extensión compilada"

# ---------------------------------------------------------------------------
# 2. Empaquetar e instalar la extensión de forma permanente
# ---------------------------------------------------------------------------
Write-Step "Verificando 'vsce' (empaquetador de extensiones)"
if (-not (Test-Command "vsce")) {
    Write-Warn "'vsce' no encontrado, instalando globalmente..."
    npm install -g @vscode/vsce
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR instalando vsce" -ForegroundColor Red; exit 1 }
}
Write-Ok "vsce disponible"

Write-Step "Empaquetando la extensión (vsce package)"
# Responder "y" automáticamente a los prompts de warnings (repository, license, etc.)
"y`ny`n" | vsce package --allow-missing-repository
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR al empaquetar" -ForegroundColor Red; exit 1 }

$vsix = Get-ChildItem -Path $extensionDir -Filter "*.vsix" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $vsix) {
    Write-Host "ERROR: no se generó ningún archivo .vsix" -ForegroundColor Red
    exit 1
}
Write-Ok "Generado: $($vsix.Name)"

Write-Step "Instalando la extensión en VS Code (permanente, sin necesitar F5)"
code --install-extension $vsix.FullName
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR instalando la extensión en VS Code" -ForegroundColor Red; exit 1 }
Write-Ok "Extensión instalada permanentemente"

Pop-Location

# ---------------------------------------------------------------------------
# 3. Instalar el servidor MCP en Python
# ---------------------------------------------------------------------------
Write-Step "Instalando el servidor MCP (pip install -e .)"
Push-Location $serverDir
pip install -e .
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR instalando el servidor Python" -ForegroundColor Red; exit 1 }
Write-Ok "Servidor MCP instalado"
Pop-Location

# ---------------------------------------------------------------------------
# 4. Registrar el servidor en claude_desktop_config.json (sin borrar nada)
# ---------------------------------------------------------------------------
Write-Step "Buscando claude_desktop_config.json"

$candidatePaths = @()
$candidatePaths += Join-Path $env:APPDATA "Claude\claude_desktop_config.json"

# Versión empaquetada (Microsoft Store) usa una carpeta virtualizada distinta
$packagesRoot = Join-Path $env:LOCALAPPDATA "Packages"
if (Test-Path $packagesRoot) {
    $storeMatch = Get-ChildItem -Path $packagesRoot -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "LocalCache\Roaming\Claude\claude_desktop_config.json" }
    $candidatePaths += $storeMatch
}

$configPath = $candidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $configPath) {
    Write-Warn "No se encontró claude_desktop_config.json automáticamente."
    Write-Warn "Abre Claude Desktop -> Settings -> Desarrollador -> 'Editar configuración' y agrega manualmente:"
    Write-Host ""
    Write-Host '  "mcpServers": { "vscode": { "command": "vscode-mcp", "env": { "VSCODE_MCP_PORT": "9877" } } }' -ForegroundColor Gray
    Write-Host ""
} else {
    Write-Ok "Encontrado: $configPath"

    $json = Get-Content -Raw -Path $configPath | ConvertFrom-Json -Depth 20

    # Convertir a hashtable editable si mcpServers no existe todavía
    if (-not $json.PSObject.Properties["mcpServers"]) {
        $json | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value ([pscustomobject]@{})
    }

    $vscodeEntry = [pscustomobject]@{
        command = "vscode-mcp"
        env     = [pscustomobject]@{ VSCODE_MCP_PORT = "9877" }
    }

    if ($json.mcpServers.PSObject.Properties["vscode"]) {
        $json.mcpServers.vscode = $vscodeEntry
        Write-Ok "Entrada 'vscode' ya existía, actualizada"
    } else {
        $json.mcpServers | Add-Member -MemberType NoteProperty -Name "vscode" -Value $vscodeEntry
        Write-Ok "Entrada 'vscode' agregada"
    }

    # Backup por si acaso, antes de sobrescribir
    Copy-Item -Path $configPath -Destination "$configPath.bak" -Force
    $json | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath -Encoding UTF8
    Write-Ok "claude_desktop_config.json actualizado (backup en claude_desktop_config.json.bak)"
}

# ---------------------------------------------------------------------------
Write-Step "Listo"
Write-Host ""
Write-Host "  Últimos pasos manuales:" -ForegroundColor White
Write-Host "  1. Cierra TODAS las ventanas de VS Code y vuelve a abrirlo (ya no hace falta F5)." -ForegroundColor White
Write-Host "  2. Verifica que aparezca 'MCP:9877' en la barra de estado (abajo a la derecha)." -ForegroundColor White
Write-Host "  3. Cierra Claude Desktop por completo (revisa la bandeja del sistema) y vuelve a abrirlo." -ForegroundColor White
Write-Host "  4. Pregúntale a Claude algo como: 'que archivo tengo abierto en VS Code?'" -ForegroundColor White
Write-Host ""
Read-Host "Presiona Enter para cerrar"
