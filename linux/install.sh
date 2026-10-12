#!/usr/bin/env bash
# install.sh
# Equivalente en Linux de install.ps1 + install.bat (bridge vscode-mcp).
# Instala automaticamente:
#   1. Dependencias + compilacion de la extension de VS Code
#   2. Empaquetado (.vsix) e instalacion permanente en VS Code
#   3. Servidor MCP en Python (dentro del venv ~/.venvs/dev)
#   4. Registro (o actualizacion) del servidor en claude_desktop_config.json
#
# USO: ejecutalo desde esta carpeta (la que contiene "extension" y "server"):
#   chmod +x install.sh
#   ./install.sh
# No lo ejecutes con sudo. Se puede correr varias veces sin problema.
#
# Ya maneja los problemas conocidos al migrar desde Windows:
#   - node_modules copiado desde Windows (tsc: Permission denied) -> se borra y reinstala
#   - mcp 2.x rompe el servidor (no existe mcp.server.fastmcp) -> pyproject fija mcp<2

set -e

paso() { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[1;32mOK:\033[0m $*"; }
aviso(){ echo -e "    \033[1;33mAVISO:\033[0m $*"; }
error(){ echo -e "\033[1;31mERROR: $*\033[0m"; exit 1; }

if [ "$EUID" -eq 0 ]; then error "No ejecutes este script como root (sin sudo)."; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$ROOT/extension"
SERVER_DIR="$ROOT/server"
VENV="$HOME/.venvs/dev"
PORT="9877"

export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

[ -d "$EXT_DIR" ]    || error "No encuentro la carpeta 'extension' en $ROOT. Pon este script dentro de vscode-mcp."
[ -d "$SERVER_DIR" ] || error "No encuentro la carpeta 'server' en $ROOT. Pon este script dentro de vscode-mcp."

# ---------------------------------------------------------------------------
# 0. Verificar requisitos
# ---------------------------------------------------------------------------
paso "Verificando requisitos (Node.js, npm, VS Code, Python)"

# Instala paquetes de apt que falten (pide la contrasena de sudo solo si hace falta)
apt_instalar() {
    command -v apt-get >/dev/null || error "No hay apt-get. Instala a mano: $*"
    aviso "Instalando con apt: $* (puede pedir tu contrasena)"
    sudo apt-get update -y || aviso "apt-get update fallo, se intenta instalar de todos modos"
    sudo apt-get install -y "$@" || error "No se pudo instalar: $*"
}

FALTAN=()
command -v python3 >/dev/null || FALTAN+=(python3)
# python3-venv y pip: Mint/Ubuntu los separan de python3
python3 -c "import venv, ensurepip" 2>/dev/null || FALTAN+=(python3-venv python3-pip)
command -v curl >/dev/null || FALTAN+=(curl)
if [ "${#FALTAN[@]}" -gt 0 ]; then apt_instalar "${FALTAN[@]}"; fi

if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
    aviso "Node.js/npm no encontrados."
    apt_instalar nodejs npm
fi
command -v node >/dev/null || error "No se encontro Node.js. Corre primero ./instalar-todo.sh"
command -v npm  >/dev/null || error "No se encontro npm. Corre primero ./instalar-todo.sh"

# Version minima de Node para compilar y empaquetar (vsce requiere Node 18+)
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 18 ]; then
    error "Node $(node -v) es muy viejo (se necesita 18 o mas). Corre primero ./instalar-todo.sh, que instala una version reciente."
fi

command -v code >/dev/null || error "No se encontro el comando 'code'. Instala VS Code con ./instalar-todo.sh y vuelve a correr este script."
ok "Node $(node -v), npm, code y python3 disponibles"

# ---------------------------------------------------------------------------
# 1. Instalar dependencias y compilar la extension
# ---------------------------------------------------------------------------
paso "Instalando dependencias de la extension (npm install)"
cd "$EXT_DIR"
# Si node_modules vino de Windows, sus binarios no son ejecutables en Linux (tsc: Permission denied).
if [ -d node_modules ] && [ ! -x node_modules/.bin/tsc ]; then
    aviso "node_modules no es valido en Linux (copiado de Windows). Se borra y se reinstala."
    rm -rf node_modules
fi
rm -f "$EXT_DIR"/*.vsix   # evita usar un .vsix viejo
npm install
ok "Dependencias instaladas"

paso "Compilando la extension (npm run compile)"
npm run compile
ok "Extension compilada"

# ---------------------------------------------------------------------------
# 2. Empaquetar e instalar la extension de forma permanente
# ---------------------------------------------------------------------------
paso "Verificando 'vsce' (empaquetador de extensiones)"
if ! command -v vsce >/dev/null; then
    aviso "'vsce' no encontrado, instalando..."
    npm config set prefix "$HOME/.npm-global"
    npm install -g @vscode/vsce
fi
ok "vsce disponible"

paso "Empaquetando la extension (vsce package)"
# Responde "y" automaticamente a los avisos (repository, license, etc.)
yes | vsce package --allow-missing-repository

VSIX="$(ls -t "$EXT_DIR"/*.vsix 2>/dev/null | head -n1)"
[ -n "$VSIX" ] || error "No se genero ningun archivo .vsix"
ok "Generado: $(basename "$VSIX")"

paso "Instalando la extension en VS Code (permanente)"
code --install-extension "$VSIX" --force
ok "Extension instalada permanentemente"

# ---------------------------------------------------------------------------
# 3. Instalar el servidor MCP en Python (en el venv ~/.venvs/dev)
# ---------------------------------------------------------------------------
paso "Instalando el servidor MCP (pip install -e .)"
if [ ! -x "$VENV/bin/pip" ]; then
    mkdir -p "$HOME/.venvs"
    python3 -m venv "$VENV" || error "No se pudo crear el venv. Instala: sudo apt install python3-venv"
fi
cd "$SERVER_DIR"
"$VENV/bin/pip" install --upgrade pip
"$VENV/bin/pip" install -e .

# Comprobar que la libreria mcp es compatible (v1.x). Con mcp 2.x el servidor no arranca.
if ! "$VENV/bin/python" -c "from mcp.server.fastmcp import FastMCP" 2>/dev/null; then
    aviso "mcp incompatible (probablemente 2.x). Instalando mcp<2..."
    "$VENV/bin/pip" install "mcp[cli]>=1.3.0,<2"
    "$VENV/bin/python" -c "from mcp.server.fastmcp import FastMCP" || error "El servidor MCP sigue sin poder importar FastMCP."
fi
ok "Libreria mcp compatible"

mkdir -p "$HOME/.local/bin"
if [ -x "$VENV/bin/vscode-mcp" ]; then
    ln -sf "$VENV/bin/vscode-mcp" "$HOME/.local/bin/vscode-mcp"
    ok "Servidor MCP instalado (comando: $HOME/.local/bin/vscode-mcp)"
else
    aviso "No aparecio el comando 'vscode-mcp' en $VENV/bin. Revisa el nombre del script en server/pyproject.toml."
fi
CMD_PATH="$HOME/.local/bin/vscode-mcp"

# ---------------------------------------------------------------------------
# 4. Registrar el servidor en claude_desktop_config.json (sin borrar nada)
# ---------------------------------------------------------------------------
paso "Buscando claude_desktop_config.json"
CONFIG=""
for c in "$HOME/.config/Claude/claude_desktop_config.json"; do
    [ -f "$c" ] && CONFIG="$c" && break
done
if [ -z "$CONFIG" ]; then
    CONFIG="$(find "$HOME/.config" -maxdepth 3 -name claude_desktop_config.json 2>/dev/null | head -n1)"
fi
# Si Claude Desktop ya creo su carpeta pero aun no el archivo, se crea
if [ -z "$CONFIG" ] && [ -d "$HOME/.config/Claude" ]; then
    CONFIG="$HOME/.config/Claude/claude_desktop_config.json"
    echo '{}' > "$CONFIG"
fi

if [ -z "$CONFIG" ]; then
    aviso "No se encontro claude_desktop_config.json."
    aviso "Abre Claude Desktop -> Settings -> Desarrollador -> 'Editar configuracion' y agrega:"
    echo
    echo "  \"mcpServers\": { \"vscode\": { \"command\": \"vscode-mcp\", \"env\": { \"VSCODE_MCP_PORT\": \"$PORT\" } } }"
    echo
else
    ok "Encontrado: $CONFIG"
    cp -f "$CONFIG" "$CONFIG.bak"
    CONFIG="$CONFIG" CMD_PATH="$CMD_PATH" PORT="$PORT" python3 - <<'PYEOF'
import json, os
path = os.environ["CONFIG"]
with open(path, encoding="utf-8") as f:
    txt = f.read().strip()
data = json.loads(txt) if txt else {}
data.setdefault("mcpServers", {})
existia = "vscode" in data["mcpServers"]
# Se usa el nombre corto "vscode-mcp" (es lo que funciona en este equipo: Claude Desktop
# lo encuentra por el PATH). Si ya habia una entrada, se conserva su "command" tal cual.
comando = "vscode-mcp"
if existia:
    comando = data["mcpServers"]["vscode"].get("command") or comando
data["mcpServers"]["vscode"] = {
    "command": comando,
    "env": {"VSCODE_MCP_PORT": os.environ["PORT"]},
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("    OK: entrada 'vscode' " + ("actualizada" if existia else "agregada"))
PYEOF
    ok "claude_desktop_config.json actualizado (backup en claude_desktop_config.json.bak)"
fi

# ---------------------------------------------------------------------------
paso "Listo"
cat <<EOF

  Ultimos pasos manuales:
  1. Cierra TODAS las ventanas de VS Code y vuelve a abrirlo.
  2. Verifica que aparezca 'MCP:$PORT' en la barra de estado (abajo a la derecha).
  3. Cierra Claude Desktop por completo y vuelve a abrirlo.
  4. Preguntale a Claude algo como: 'que archivo tengo abierto en VS Code?'

  Si Claude Desktop no encuentra el comando 'vscode-mcp' (el bridge no responde),
  cierra sesion en Linux y vuelve a entrar: asi ~/.local/bin entra en el PATH.

EOF
