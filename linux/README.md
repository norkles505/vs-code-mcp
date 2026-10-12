# vscode-mcp

Puente MCP para VS Code, con el mismo patrón arquitectónico que
[blender-mcp](https://github.com/ahujasid/blender-mcp): una extensión que vive
dentro de la aplicación (VS Code) abre un socket TCP local, y un servidor MCP
externo le manda comandos JSON por ese socket.

```
┌─────────────┐   MCP (stdio)   ┌──────────────┐   TCP socket   ┌────────────────┐
│ Claude / IA  │ ─────────────► │ server.py     │ ─────────────► │ extension.ts    │
│ (cliente MCP)│ ◄───────────── │ (FastMCP)     │ ◄───────────── │ (dentro de VSC) │
└─────────────┘                 └──────────────┘                 └────────────────┘
```

## Instalación rápida (Linux)

```bash
chmod +x install.sh
./install.sh
```

(Siempre desde una terminal, no con doble clic. Si no quieres usar `chmod`,
también sirve `bash install.sh`. No lo corras con `sudo`: pide la contraseña
solo cuando necesita instalar algo con apt.)

Si faltan `python3-venv`, `pip`, `curl` o Node/npm, el script los instala con apt.
Lo único que no instala solo es VS Code (comando `code`): para eso corre antes
`./instalar-todo.sh`.

Hace todo solo: compila la extensión, la empaqueta e instala en VS Code, instala el
servidor MCP en el venv `~/.venvs/dev` y lo registra en
`~/.config/Claude/claude_desktop_config.json`. Se puede ejecutar varias veces.

Después: cierra y abre VS Code (debe aparecer `MCP:9877` en la barra de estado) y
reinicia Claude Desktop por completo.

Notas de compatibilidad con Linux:
- Si `node_modules` vino copiado de Windows, `install.sh` lo borra y lo reinstala
  (si no, falla con `tsc: Permission denied`).
- El servidor requiere `mcp<2` (con mcp 2.x ya no existe `mcp.server.fastmcp`).
  `server/pyproject.toml` ya lo fija.
- En Mint/Ubuntu 24.04 no se usa `pip` global (PEP 668), por eso se usa un venv.

## 1. Instalar y compilar la extensión (manual)

```bash
cd extension
npm install
npm run compile
```

Luego, para probarla sin publicarla:
- Abre la carpeta `extension/` en VS Code
- Presiona `F5` → se abre una "Extension Development Host" con el bridge activo
- Verás en la barra de estado (abajo a la derecha) algo como `🔌 MCP:9877`

(Para instalarla de forma permanente en tu VS Code normal, hay que empaquetarla
con `vsce package` y luego `code --install-extension vscode-mcp-bridge-0.1.0.vsix`)

## 2. Instalar el servidor MCP (manual)

```bash
cd server
~/.venvs/dev/bin/pip install -e .
ln -sf ~/.venvs/dev/bin/vscode-mcp ~/.local/bin/vscode-mcp
```

## 3. Registrar el servidor MCP en tu cliente (manual)

Si usas Claude Desktop, en `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "vscode": {
      "command": "vscode-mcp",
      "env": {
        "VSCODE_MCP_PORT": "9877"
      }
    }
  }
}
```

## Herramientas disponibles

- `get_workspace_info` — carpetas del workspace abierto
- `get_open_files` — tabs abiertos, cuál está activo
- `get_active_editor` — archivo activo, contenido, cursor, selección
- `get_diagnostics` — errores/warnings del linter/TS
- `list_workspace_files` — buscar archivos por patrón glob
- `read_file` — leer un archivo (respeta buffer sin guardar)
- `edit_file` — reescribir un archivo completo (undo-able)
- `apply_patch` — reemplazar un fragmento específico de texto
- `run_in_terminal` — mandar un comando a una terminal integrada
- `execute_vscode_command` — ejecutar cualquier comando nativo de VS Code

## Notas de diseño

- **Puerto 9877** por defecto (Blender usa 9876) para poder correr ambos MCP a la vez.
- `edit_file` / `apply_patch` usan `WorkspaceEdit`, no escritura directa a disco,
  así los cambios son deshacer-ables con Ctrl+Z y se reflejan en vivo si el
  archivo está abierto.
- `run_in_terminal` no puede leer la salida del comando (las terminales de VS
  Code no exponen stdout por API pública). Si necesitas capturar output,
  conviene correr el comando directamente desde Python con `subprocess` en vez
  de pasarlo por la terminal visual.
