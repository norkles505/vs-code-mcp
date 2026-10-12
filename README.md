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

## 1. Instalar y compilar la extensión

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

## 2. Instalar el servidor MCP

```bash
cd server
pip install -e .
```

## 3. Registrar el servidor MCP en tu cliente

Si usas Claude Desktop, en `claude_desktop_config.json`:

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
