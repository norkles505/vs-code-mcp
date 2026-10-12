"""
vscode_mcp_server.py

Servidor MCP que hace de puente entre un cliente MCP (Claude, etc.) y una
extensión de VS Code corriendo localmente. La extensión abre un socket TCP
(ver extension/src/extension.ts) y este servidor le manda comandos JSON,
exactamente igual que blender-mcp habla con el addon.py de Blender.
"""

from mcp.server.fastmcp import FastMCP, Context
import socket
import json
import logging
import os
from dataclasses import dataclass
from contextlib import asynccontextmanager
from typing import AsyncIterator, Dict, Any

logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("VSCodeMCPServer")

DEFAULT_HOST = "localhost"
DEFAULT_PORT = 9877  # Puerto distinto al de Blender (9876) para poder correr ambos a la vez


@dataclass
class VSCodeConnection:
    host: str
    port: int
    sock: socket.socket = None

    def connect(self) -> bool:
        if self.sock:
            return True
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.connect((self.host, self.port))
            logger.info(f"Connected to VS Code extension at {self.host}:{self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to VS Code extension: {e}")
            self.sock = None
            return False

    def disconnect(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            finally:
                self.sock = None

    def receive_full_response(self, sock, buffer_size=8192) -> bytes:
        chunks = []
        sock.settimeout(30.0)
        while True:
            try:
                chunk = sock.recv(buffer_size)
                if not chunk:
                    if not chunks:
                        raise Exception("Connection closed before receiving any data")
                    break
                chunks.append(chunk)
                data = b"".join(chunks)
                try:
                    json.loads(data.decode("utf-8"))
                    return data  # JSON completo y válido
                except UnicodeDecodeError:
                    # Un carácter multi-byte (tildes, ñ, etc.) quedó cortado
                    # justo en el límite del chunk. Todavía no llegaron todos
                    # sus bytes: seguimos esperando más datos, no es un error.
                    continue
                except json.JSONDecodeError:
                    continue  # Sigue esperando más bytes
            except socket.timeout:
                logger.warning("Timeout esperando respuesta de VS Code")
                break
        if chunks:
            return b"".join(chunks)
        raise Exception("No data received")

    def send_command(self, command_type: str, params: Dict[str, Any] = None) -> Dict[str, Any]:
        if not self.sock and not self.connect():
            raise ConnectionError("No conectado a la extensión de VS Code")

        command = {"type": command_type, "params": params or {}}
        try:
            self.sock.sendall(json.dumps(command).encode("utf-8"))
            self.sock.settimeout(30.0)
            response_data = self.receive_full_response(self.sock)
            response = json.loads(response_data.decode("utf-8"))
            if response.get("status") == "error":
                raise Exception(response.get("message", "Error desconocido de VS Code"))
            return response.get("result", {})
        except socket.timeout:
            self.sock = None
            raise Exception("Timeout esperando respuesta de VS Code")
        except (ConnectionError, BrokenPipeError, ConnectionResetError) as e:
            self.sock = None
            raise Exception(f"Conexión perdida con VS Code: {e}")


_vscode_connection: VSCodeConnection = None


def get_vscode_connection() -> VSCodeConnection:
    global _vscode_connection
    if _vscode_connection is not None:
        try:
            _vscode_connection.send_command("ping")
            return _vscode_connection
        except Exception:
            logger.warning("Conexión existente inválida, reconectando...")
            _vscode_connection.disconnect()
            _vscode_connection = None

    host = os.getenv("VSCODE_MCP_HOST", DEFAULT_HOST)
    port = int(os.getenv("VSCODE_MCP_PORT", DEFAULT_PORT))
    conn = VSCodeConnection(host=host, port=port)
    if not conn.connect():
        raise Exception(
            "No se pudo conectar a VS Code. Asegúrate de que la extensión "
            "'vscode-mcp-bridge' esté instalada y activa (revisa la barra de estado)."
        )
    _vscode_connection = conn
    return _vscode_connection


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[Dict[str, Any]]:
    logger.info("VSCodeMCP server starting up")
    try:
        get_vscode_connection()
        logger.info("Conectado a VS Code al arrancar")
    except Exception as e:
        logger.warning(f"No se pudo conectar a VS Code al arrancar: {e}")
    try:
        yield {}
    finally:
        global _vscode_connection
        if _vscode_connection:
            _vscode_connection.disconnect()
            _vscode_connection = None
        logger.info("VSCodeMCP server shut down")


mcp = FastMCP("VSCodeMCP", lifespan=server_lifespan)


# ---------------------------------------------------------------------------
# Tools: estado del editor / workspace
# ---------------------------------------------------------------------------

@mcp.tool()
def get_workspace_info(ctx: Context) -> str:
    """Obtiene información del workspace abierto en VS Code: carpetas raíz, nombre, etc."""
    try:
        vs = get_vscode_connection()
        result = vs.send_command("get_workspace_info")
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def get_project_tree(ctx: Context, max_depth: int = 6, max_entries: int = 1500) -> str:
    """
    Obtiene el árbol completo de carpetas y archivos del proyecto abierto en VS Code,
    excluyendo automáticamente carpetas que no aportan contexto (node_modules, .git,
    dist, build, __pycache__, venv, etc.). Útil para que tengas una visión general de
    cómo está organizado el proyecto antes de leer archivos específicos.

    Parameters:
    - max_depth: profundidad máxima de recursión (default 6)
    - max_entries: máximo de archivos/carpetas a incluir antes de truncar (default 1500)
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("get_project_tree", {
            "max_depth": max_depth,
            "max_entries": max_entries,
        })
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def get_open_files(ctx: Context) -> str:
    """Lista todos los archivos actualmente abiertos (tabs) en VS Code, indicando cuál es el activo."""
    try:
        vs = get_vscode_connection()
        result = vs.send_command("get_open_files")
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def get_active_editor(ctx: Context) -> str:
    """
    Devuelve el archivo activo en VS Code: ruta, contenido actual (incluye cambios
    sin guardar), posición del cursor y el texto seleccionado si hay selección.
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("get_active_editor")
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def get_diagnostics(ctx: Context, file_path: str = None) -> str:
    """
    Obtiene errores y warnings (diagnostics) del editor: linter, TypeScript, etc.

    Parameters:
    - file_path: ruta absoluta de un archivo específico. Si se omite, devuelve
      diagnostics de todo el workspace.
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("get_diagnostics", {"file_path": file_path})
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


# ---------------------------------------------------------------------------
# Tools: archivos
# ---------------------------------------------------------------------------

@mcp.tool()
def list_workspace_files(ctx: Context, glob_pattern: str = "**/*", max_results: int = 200) -> str:
    """
    Lista archivos del workspace que coinciden con un patrón glob (ej. "**/*.ts").

    Parameters:
    - glob_pattern: patrón glob relativo al workspace (por defecto todos los archivos)
    - max_results: máximo de resultados a devolver
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("list_workspace_files", {
            "glob_pattern": glob_pattern,
            "max_results": max_results,
        })
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def read_file(ctx: Context, file_path: str) -> str:
    """
    Lee un archivo a través de VS Code (respeta el buffer en memoria si el
    archivo está abierto con cambios sin guardar).

    Parameters:
    - file_path: ruta absoluta del archivo
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("read_file", {"file_path": file_path})
        return result.get("content", "")
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def edit_file(ctx: Context, file_path: str, new_content: str, save: bool = True) -> str:
    """
    Reemplaza el contenido completo de un archivo usando WorkspaceEdit de VS Code,
    lo cual permite deshacer con Ctrl+Z y se ve reflejado en vivo en el editor.

    Parameters:
    - file_path: ruta absoluta del archivo (se abre si no está abierto)
    - new_content: contenido completo nuevo del archivo
    - save: si True, guarda el archivo después de editar (default True)
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("edit_file", {
            "file_path": file_path,
            "new_content": new_content,
            "save": save,
        })
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def apply_patch(ctx: Context, file_path: str, old_text: str, new_text: str, save: bool = True) -> str:
    """
    Reemplaza una porción específica de texto dentro de un archivo (como str_replace),
    en vez de reescribir el archivo completo. old_text debe aparecer exactamente una vez.

    Parameters:
    - file_path: ruta absoluta del archivo
    - old_text: texto exacto a reemplazar (debe ser único en el archivo)
    - new_text: texto de reemplazo
    - save: si True, guarda el archivo después de editar
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("apply_patch", {
            "file_path": file_path,
            "old_text": old_text,
            "new_text": new_text,
            "save": save,
        })
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


# ---------------------------------------------------------------------------
# Tools: terminal y comandos
# ---------------------------------------------------------------------------

@mcp.tool()
def run_in_terminal(ctx: Context, command: str, terminal_name: str = "MCP") -> str:
    """
    Ejecuta un comando en una terminal integrada de VS Code (la crea si no existe).
    No captura la salida (las terminales de VS Code no exponen stdout por API);
    para obtener resultados usa un enfoque basado en archivos o bash_tool aparte.

    Parameters:
    - command: comando de shell a ejecutar
    - terminal_name: nombre de la terminal a usar/crear
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("run_in_terminal", {
            "command": command,
            "terminal_name": terminal_name,
        })
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


@mcp.tool()
def execute_vscode_command(ctx: Context, command_id: str, args: list = None) -> str:
    """
    Ejecuta cualquier comando nativo de VS Code por su ID (ej. "workbench.action.files.save",
    "editor.action.formatDocument", "workbench.action.debug.start").

    Parameters:
    - command_id: el ID del comando de VS Code
    - args: lista opcional de argumentos para el comando
    """
    try:
        vs = get_vscode_connection()
        result = vs.send_command("execute_vscode_command", {
            "command_id": command_id,
            "args": args or [],
        })
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"Error: {e}"


def main():
    mcp.run()


if __name__ == "__main__":
    main()