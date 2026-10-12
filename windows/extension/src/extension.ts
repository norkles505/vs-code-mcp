// extension.ts
//
// Extensión "puente": abre un servidor TCP local y ejecuta comandos que le
// llegan como JSON, exactamente como addon.py hace dentro de Blender.
// El servidor MCP en Python (server/src/vscode_mcp/server.py) es el que
// manda estos comandos.

import * as vscode from 'vscode';
import * as net from 'net';

const DEFAULT_PORT = 9877;
let server: net.Server | undefined;
let statusBarItem: vscode.StatusBarItem;

interface Command {
  type: string;
  params: Record<string, any>;
}

function sendJson(socket: net.Socket, payload: any) {
  socket.write(JSON.stringify(payload));
}

async function handleCommand(cmd: Command): Promise<any> {
  const { type, params } = cmd;

  switch (type) {
    case 'ping':
      return { ok: true };

    case 'get_workspace_info':
      return getWorkspaceInfo();

    case 'get_project_tree':
      return getProjectTree(params.max_depth, params.max_entries);

    case 'get_open_files':
      return getOpenFiles();

    case 'get_active_editor':
      return getActiveEditor();

    case 'get_diagnostics':
      return getDiagnostics(params.file_path);

    case 'list_workspace_files':
      return listWorkspaceFiles(params.glob_pattern, params.max_results);

    case 'read_file':
      return readFile(params.file_path);

    case 'edit_file':
      return editFile(params.file_path, params.new_content, params.save);

    case 'apply_patch':
      return applyPatch(params.file_path, params.old_text, params.new_text, params.save);

    case 'run_in_terminal':
      return runInTerminal(params.command, params.terminal_name);

    case 'execute_vscode_command':
      return executeVscodeCommand(params.command_id, params.args);

    default:
      throw new Error(`Comando desconocido: ${type}`);
  }
}

// ---------------------------------------------------------------------------
// Implementaciones de cada comando
// ---------------------------------------------------------------------------

function getWorkspaceInfo() {
  const folders = vscode.workspace.workspaceFolders || [];
  return {
    name: vscode.workspace.name || null,
    folders: folders.map(f => ({ name: f.name, path: f.uri.fsPath })),
  };
}

// Carpetas/archivos que casi nunca aportan contexto útil y sí inflan mucho la respuesta
const TREE_EXCLUDE = new Set([
  'node_modules', '.git', 'dist', 'build', 'out', '__pycache__',
  '.venv', 'venv', '.next', 'coverage', '.vscode-test', '.pytest_cache',
  '.mypy_cache', 'target', '.gradle', '.idea', '.DS_Store',
]);

interface TreeNode {
  name: string;
  type: 'file' | 'directory';
  children?: TreeNode[];
  truncated?: boolean;
}

async function getProjectTree(maxDepth = 6, maxEntries = 1500) {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    return { error: 'No hay ningún workspace (carpeta) abierto en VS Code' };
  }

  let count = 0;

  async function walk(uri: vscode.Uri, name: string, depth: number): Promise<TreeNode> {
    let entries: [string, vscode.FileType][];
    try {
      entries = await vscode.workspace.fs.readDirectory(uri);
    } catch (e: any) {
      return { name, type: 'directory', children: [], truncated: true };
    }

    const node: TreeNode = { name, type: 'directory', children: [] };

    if (depth >= maxDepth) {
      node.truncated = true;
      return node;
    }

    entries.sort((a, b) => a[0].localeCompare(b[0]));

    for (const [entryName, fileType] of entries) {
      if (TREE_EXCLUDE.has(entryName)) continue;
      if (count >= maxEntries) {
        node.truncated = true;
        break;
      }
      count++;

      const childUri = vscode.Uri.joinPath(uri, entryName);
      if (fileType === vscode.FileType.Directory) {
        node.children!.push(await walk(childUri, entryName, depth + 1));
      } else {
        node.children!.push({ name: entryName, type: 'file' });
      }
    }

    return node;
  }

  // Si hay varios workspace folders (multi-root), armamos un árbol por cada uno
  const trees = await Promise.all(
    folders.map(f => walk(f.uri, f.name, 0))
  );

  return {
    roots: trees,
    total_entries: count,
    truncated: count >= maxEntries,
    max_depth_used: maxDepth,
  };
}

function getOpenFiles() {
  const activeUri = vscode.window.activeTextEditor?.document.uri.fsPath;
  const tabs: { path: string; is_dirty: boolean; is_active: boolean }[] = [];

  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      if (tab.input instanceof vscode.TabInputText) {
        const path = tab.input.uri.fsPath;
        tabs.push({
          path,
          is_dirty: tab.isDirty,
          is_active: path === activeUri,
        });
      }
    }
  }
  return { open_files: tabs };
}

function getActiveEditor() {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    return { active: false, message: 'No hay ningún editor activo' };
  }
  const doc = editor.document;
  const selection = editor.selection;
  return {
    active: true,
    file_path: doc.uri.fsPath,
    language_id: doc.languageId,
    is_dirty: doc.isDirty,
    content: doc.getText(),
    cursor: { line: selection.active.line, character: selection.active.character },
    selection: selection.isEmpty ? null : doc.getText(selection),
  };
}

function getDiagnostics(filePath?: string) {
  const collect = (uri: vscode.Uri) =>
    vscode.languages.getDiagnostics(uri).map(d => ({
      message: d.message,
      severity: vscode.DiagnosticSeverity[d.severity],
      line: d.range.start.line + 1,
      character: d.range.start.character,
      source: d.source || null,
    }));

  if (filePath) {
    const uri = vscode.Uri.file(filePath);
    return { file: filePath, diagnostics: collect(uri) };
  }

  const all = vscode.languages.getDiagnostics();
  const result: Record<string, any[]> = {};
  for (const [uri, diags] of all) {
    if (diags.length > 0) {
      result[uri.fsPath] = diags.map(d => ({
        message: d.message,
        severity: vscode.DiagnosticSeverity[d.severity],
        line: d.range.start.line + 1,
        character: d.range.start.character,
        source: d.source || null,
      }));
    }
  }
  return { diagnostics_by_file: result };
}

async function listWorkspaceFiles(globPattern = '**/*', maxResults = 200) {
  const uris = await vscode.workspace.findFiles(
    globPattern,
    '**/node_modules/**',
    maxResults
  );
  return { files: uris.map(u => u.fsPath), count: uris.length };
}

async function readFile(filePath: string) {
  const uri = vscode.Uri.file(filePath);
  // Si el archivo ya está abierto (con cambios sin guardar), usamos ese buffer
  const openDoc = vscode.workspace.textDocuments.find(d => d.uri.fsPath === filePath);
  if (openDoc) {
    return { content: openDoc.getText(), from_buffer: true };
  }
  const doc = await vscode.workspace.openTextDocument(uri);
  return { content: doc.getText(), from_buffer: false };
}

async function editFile(filePath: string, newContent: string, save = true) {
  const uri = vscode.Uri.file(filePath);
  let doc: vscode.TextDocument;
  try {
    doc = await vscode.workspace.openTextDocument(uri);
  } catch {
    // El archivo no existe todavía: lo creamos
    const edit = new vscode.WorkspaceEdit();
    edit.createFile(uri, { ignoreIfExists: true });
    await vscode.workspace.applyEdit(edit);
    doc = await vscode.workspace.openTextDocument(uri);
  }

  const fullRange = new vscode.Range(
    doc.positionAt(0),
    doc.positionAt(doc.getText().length)
  );

  const edit = new vscode.WorkspaceEdit();
  edit.replace(uri, fullRange, newContent);
  const applied = await vscode.workspace.applyEdit(edit);

  if (save) {
    const freshDoc = vscode.workspace.textDocuments.find(d => d.uri.fsPath === filePath);
    await freshDoc?.save();
  }

  return { success: applied, file_path: filePath, saved: save };
}

async function applyPatch(filePath: string, oldText: string, newText: string, save = true) {
  const uri = vscode.Uri.file(filePath);
  const doc = await vscode.workspace.openTextDocument(uri);
  const fullText = doc.getText();

  const firstIndex = fullText.indexOf(oldText);
  if (firstIndex === -1) {
    throw new Error('old_text no encontrado en el archivo');
  }
  const lastIndex = fullText.lastIndexOf(oldText);
  if (firstIndex !== lastIndex) {
    throw new Error('old_text aparece más de una vez; debe ser único');
  }

  const startPos = doc.positionAt(firstIndex);
  const endPos = doc.positionAt(firstIndex + oldText.length);
  const range = new vscode.Range(startPos, endPos);

  const edit = new vscode.WorkspaceEdit();
  edit.replace(uri, range, newText);
  const applied = await vscode.workspace.applyEdit(edit);

  if (save) {
    await doc.save();
  }

  return { success: applied, file_path: filePath, saved: save };
}

function runInTerminal(command: string, terminalName = 'MCP') {
  let terminal = vscode.window.terminals.find(t => t.name === terminalName);
  if (!terminal) {
    terminal = vscode.window.createTerminal(terminalName);
  }
  terminal.show();
  terminal.sendText(command);
  return { success: true, terminal: terminalName };
}

async function executeVscodeCommand(commandId: string, args: any[] = []) {
  const result = await vscode.commands.executeCommand(commandId, ...args);
  return { success: true, result: result ?? null };
}

// ---------------------------------------------------------------------------
// Servidor TCP (igual patrón que el _server_loop de addon.py)
// ---------------------------------------------------------------------------

function startServer(port: number) {
  server = net.createServer(socket => {
    let chunks: Buffer[] = [];

    socket.on('data', async data => {
      // Acumulamos los bytes crudos y sólo decodificamos como UTF-8 una vez
      // que tenemos todo el buffer junto. Decodificar cada chunk por
      // separado (como antes) corrompe en silencio los caracteres
      // multi-byte (tildes, ñ) que quedan cortados entre dos chunks TCP.
      chunks.push(data);
      const combined = Buffer.concat(chunks);
      let command: Command;
      try {
        command = JSON.parse(combined.toString('utf-8'));
      } catch {
        return; // JSON incompleto (o corte a mitad de un char), esperar más datos
      }
      chunks = [];

      try {
        const result = await handleCommand(command);
        sendJson(socket, { status: 'success', result });
      } catch (err: any) {
        sendJson(socket, { status: 'error', message: err?.message ?? String(err) });
      }
    });

    socket.on('error', () => {
      // Cliente desconectado abruptamente; nada que hacer
    });
  });

  server.listen(port, 'localhost', () => {
    updateStatusBar(true, port);
    vscode.window.showInformationMessage(`VS Code MCP Bridge escuchando en puerto ${port}`);
  });

  server.on('error', (err: any) => {
    vscode.window.showErrorMessage(`VS Code MCP Bridge: error de servidor - ${err.message}`);
    updateStatusBar(false, port);
  });
}

function stopServer() {
  server?.close();
  server = undefined;
  updateStatusBar(false, DEFAULT_PORT);
}

function showStatus(port: number) {
  const folders = vscode.workspace.workspaceFolders;
  const folderText = folders && folders.length > 0
    ? `Proyecto abierto: ${folders.map(f => f.name).join(', ')}`
    : 'Ningún proyecto abierto todavía';

  if (server) {
    vscode.window.showInformationMessage(
      `✅ Conectado con Claude (puerto ${port}). ${folderText}`
    );
  } else {
    vscode.window
      .showWarningMessage('❌ No conectado. ¿Iniciar la conexión con Claude ahora?', 'Conectar')
      .then(choice => {
        if (choice === 'Conectar') {
          startServer(port);
        }
      });
  }
}

function updateStatusBar(running: boolean, port: number) {
  statusBarItem.text = running ? `$(plug) MCP:${port}` : '$(debug-disconnect) MCP off';
  statusBarItem.tooltip = running
    ? `VS Code MCP Bridge activo en el puerto ${port}. Click para detener.`
    : 'VS Code MCP Bridge detenido. Click para iniciar.';
  statusBarItem.command = running ? 'vscodeMcpBridge.stop' : 'vscodeMcpBridge.start';
}

// ---------------------------------------------------------------------------
// Activación de la extensión
// ---------------------------------------------------------------------------

export function activate(context: vscode.ExtensionContext) {
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBarItem.show();
  context.subscriptions.push(statusBarItem);

  context.subscriptions.push(
    vscode.commands.registerCommand('vscodeMcpBridge.start', () => {
      const port = vscode.workspace.getConfiguration('vscodeMcpBridge').get<number>('port', DEFAULT_PORT);
      startServer(port);
    }),
    vscode.commands.registerCommand('vscodeMcpBridge.stop', () => {
      stopServer();
      vscode.window.showInformationMessage('VS Code MCP Bridge detenido');
    }),
    vscode.commands.registerCommand('vscodeMcpBridge.status', () => {
      const port = vscode.workspace.getConfiguration('vscodeMcpBridge').get<number>('port', DEFAULT_PORT);
      showStatus(port);
    })
  );

  const autoStart = vscode.workspace.getConfiguration('vscodeMcpBridge').get<boolean>('autoStart', true);
  if (autoStart) {
    const port = vscode.workspace.getConfiguration('vscodeMcpBridge').get<number>('port', DEFAULT_PORT);
    startServer(port);
  } else {
    updateStatusBar(false, DEFAULT_PORT);
  }
}

export function deactivate() {
  stopServer();
}