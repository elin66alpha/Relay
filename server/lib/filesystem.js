'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { randomUUID } = require('crypto');

const { getDefaultWorkdir, ensureWorkdirExists } = require('./workdir');
const { TOKENS_FILE } = require('./tokens');
const { SERVICE_ACCOUNT_FILE } = require('./fcm');
const { CURSOR_CONFIG_DIR, cursorAuthFile } = require('./cli-paths');

class FilesystemError extends Error {
  constructor(message, { status = 400, code = 'FS_ERROR' } = {}) {
    super(message);
    this.name = 'FilesystemError';
    this.status = status;
    this.code = code;
  }
}

function isInside(parent, child) {
  return child === parent || child.startsWith(`${parent}${path.sep}`);
}

// --- access policy ------------------------------------------------------------
//
// The file API is deliberately filesystem-wide (the unified browser can reach
// anything the server user can), but a leaked device token must not be able to
// escalate: reading tokens.json/.env mints new credentials, and reading the CLI
// auth files or ~/.ssh takes over accounts beyond Relay. Those paths are always
// refused, for download, upload, and listing alike. Everything else stays
// reachable unless RELAY_FS_ROOTS narrows the API to an explicit allowlist
// (comma-separated absolute paths); agent execution is not affected either way.

const SERVER_DIR = path.resolve(__dirname, '..');

const SENSITIVE_PATHS = [
  // Taken from tokens.js rather than rebuilt here, so RELAY_TOKENS_FILE cannot
  // move the token store out from under the denylist.
  TOKENS_FILE,
  path.join(SERVER_DIR, '.env'),
  path.join(SERVER_DIR, 'credentials'),
  path.join(SERVER_DIR, 'push-subscriptions.json'),
  path.join(SERVER_DIR, 'fcm-tokens.json'),
  // A Google service-account key: whoever holds it can send as the project.
  // The configured path, plus the conventional one in case FCM is off.
  ...(SERVICE_ACCOUNT_FILE ? [SERVICE_ACCOUNT_FILE] : []),
  path.join(SERVER_DIR, 'fcm-service-account.json'),
  path.join(os.homedir(), '.ssh'),
  path.join(os.homedir(), '.claude', '.credentials.json'),
  path.join(os.homedir(), '.codex', 'auth.json'),
  cursorAuthFile(),
  // Relay's own Cursor config: model choices, settings and session transcripts.
  CURSOR_CONFIG_DIR,
];

const FS_ROOTS = String(process.env.RELAY_FS_ROOTS || '')
  .split(',')
  .map((entry) => entry.trim())
  .filter(Boolean)
  .map((entry) => path.resolve(entry));

function restrictedError() {
  return new FilesystemError('path is restricted', {
    status: 403,
    code: 'FS_PATH_RESTRICTED',
  });
}

// Refuse a target that is a sensitive path, lives inside one, or is one of the
// dot-suffixed siblings beside one. When RELAY_FS_ROOTS is set, the target
// must also fall under one of the configured roots.
function assertPathAllowed(target) {
  const resolved = path.resolve(target);
  for (const sensitive of SENSITIVE_PATHS) {
    if (isInside(sensitive, resolved) || resolved.startsWith(`${sensitive}.`)) {
      throw restrictedError();
    }
  }
  if (FS_ROOTS.length && !FS_ROOTS.some((root) => isInside(root, resolved))) {
    throw new FilesystemError('path is outside the allowed roots', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_ROOTS',
    });
  }
  if (fs.existsSync(resolved)) {
    const realTarget = fs.realpathSync(resolved);
    if (realTarget !== resolved) assertPathAllowed(realTarget);
  }
}

// Directory downloads additionally refuse trees that *contain* a sensitive path
// — zipping the server directory (or any ancestor) would otherwise exfiltrate
// tokens.json inside the archive.
function assertTreeAllowed(target) {
  assertPathAllowed(target);
  const resolved = path.resolve(target);
  for (const sensitive of SENSITIVE_PATHS) {
    if (isInside(resolved, sensitive)) {
      throw restrictedError();
    }
  }
  const realTarget = fs.realpathSync(resolved);
  if (realTarget !== resolved) assertTreeAllowed(realTarget);
}

function normalizeRelative(input) {
  const text = String(input || '').trim().replace(/\\/g, '/');
  if (!text || text === '.') return '';
  if (path.isAbsolute(text)) {
    throw new FilesystemError('file browser paths must be relative to workdir', {
      status: 400,
      code: 'FS_PATH_MUST_BE_RELATIVE',
    });
  }
  const normalized = path.posix.normalize(text);
  if (normalized === '.' || normalized === '/') return '';
  if (normalized === '..' || normalized.startsWith('../')) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  return normalized;
}

function toApiPath(root, target) {
  return path.relative(root, target).split(path.sep).filter(Boolean).join('/');
}

function currentRoot(workdir) {
  const root = path.resolve(ensureWorkdirExists(workdir));
  const realRoot = fs.realpathSync(root);
  return { root, realRoot };
}

function resolveExisting(relativePath, workdir) {
  const { root, realRoot } = currentRoot(workdir);
  const relative = normalizeRelative(relativePath);
  const target = path.resolve(root, relative);
  if (!isInside(root, target)) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  let stat;
  let realTarget;
  try {
    stat = fs.statSync(target);
    realTarget = fs.realpathSync(target);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!isInside(realRoot, realTarget)) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  assertPathAllowed(target);
  return {
    root,
    realRoot,
    target,
    realTarget,
    relative: toApiPath(root, target),
    stat,
  };
}

async function entryFor(root, target, dirent, { absolutePaths = false } = {}) {
  const stat = await fs.promises.lstat(target);
  let type = 'other';
  if (stat.isDirectory()) {
    type = 'directory';
  } else if (stat.isFile()) {
    type = 'file';
  }
  return {
    name: dirent.name,
    path: absolutePaths ? target : toApiPath(root, target),
    absolutePath: target,
    type,
    size: stat.size,
    modifiedAt: stat.mtime.toISOString(),
  };
}

async function visibleDirents(target, { showHidden = false } = {}) {
  const dirents = await fs.promises.readdir(target, { withFileTypes: true });
  return dirents.filter((dirent) => showHidden || !dirent.name.startsWith('.'));
}

function sortEntries(entries) {
  return entries.sort((a, b) => {
    if (a.type === 'directory' && b.type !== 'directory') return -1;
    if (a.type !== 'directory' && b.type === 'directory') return 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
  });
}

async function listAbsoluteDirectory(value, { showHidden = false, fallbackDir } = {}) {
  const raw = String(value || '').trim();
  if (raw && !path.isAbsolute(raw)) {
    throw new FilesystemError('directory browser path must be absolute', {
      status: 400,
      code: 'FS_PATH_MUST_BE_ABSOLUTE',
    });
  }
  const target = path.resolve(raw || fallbackDir || getDefaultWorkdir());
  let stat;
  try {
    stat = await fs.promises.stat(target);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!stat.isDirectory()) {
    throw new FilesystemError('path is not a directory', {
      status: 400,
      code: 'FS_PATH_NOT_DIRECTORY',
    });
  }
  assertPathAllowed(target);
  const root = path.parse(target).root;
  const dirents = await visibleDirents(target, { showHidden });
  const entries = sortEntries(
    (
      await Promise.all(
        dirents.map((dirent) =>
          entryFor(root, path.join(target, dirent.name), dirent, {
            absolutePaths: true,
          }).catch(() => null),
        ),
      )
    ).filter(Boolean),
  );
  return {
    root,
    path: target,
    absolutePath: target,
    parentPath: target === root ? null : path.dirname(target),
    entries,
  };
}

// Sum regular file sizes until maxBytes is exceeded. Symlinks are
// skipped so the walk cannot loop or escape via a linked directory. Used to
// reject directory (zip) downloads before we start streaming, since the tunnel
// has a hard size budget and a half-sent zip cannot become a clean error.
// Async + yielding between syscalls so walking a large tree (e.g. node_modules)
// does not block the single-threaded server for every other client and agent.
async function directorySize(dir, maxBytes) {
  let total = 0;
  const stack = [dir];
  while (stack.length) {
    const current = stack.pop();
    let dirents;
    try {
      dirents = await fs.promises.readdir(current, { withFileTypes: true });
    } catch (_err) {
      continue;
    }
    for (const dirent of dirents) {
      // The dirent already classifies the entry without following symlinks, so
      // we only need a stat for the size of regular files.
      if (dirent.isSymbolicLink()) continue;
      const full = path.join(current, dirent.name);
      if (dirent.isDirectory()) {
        stack.push(full);
      } else if (dirent.isFile()) {
        try {
          total += (await fs.promises.lstat(full)).size;
          if (maxBytes > 0 && total > maxBytes) return total;
        } catch (_err) {
          // Skip entries that vanish or can't be stat'd mid-walk.
        }
      }
    }
  }
  return total;
}

// Download by absolute path so the unified file browser can fetch anything the
// user can navigate to (the browser already exposes the whole filesystem up to
// root). `maxBytes`, when set, caps the download: a single file by its size, a
// directory by its uncompressed total (which is >= the resulting zip, so the
// zip is guaranteed to fit). Over-limit throws before any bytes are streamed.
async function prepareDownloadAbsolute(value, { maxBytes } = {}) {
  const raw = String(value || '').trim();
  if (!raw || !path.isAbsolute(raw)) {
    throw new FilesystemError('download path must be absolute', {
      status: 400,
      code: 'FS_PATH_MUST_BE_ABSOLUTE',
    });
  }
  const target = path.resolve(raw);
  let stat;
  try {
    stat = await fs.promises.stat(target);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!stat.isFile() && !stat.isDirectory()) {
    throw new FilesystemError('only files and directories can be downloaded', {
      status: 400,
      code: 'FS_UNSUPPORTED_DOWNLOAD',
    });
  }
  const isDirectory = stat.isDirectory();
  if (isDirectory) assertTreeAllowed(target);
  else assertPathAllowed(target);
  const totalBytes = isDirectory ? await directorySize(target, maxBytes) : stat.size;
  if (typeof maxBytes === 'number' && maxBytes > 0 && totalBytes > maxBytes) {
    throw new FilesystemError('download exceeds the size limit', {
      status: 413,
      code: 'FS_DOWNLOAD_TOO_LARGE',
      meta: { totalBytes, maxBytes },
    });
  }
  const basename = path.basename(target) || 'download';
  return {
    target,
    isDirectory,
    totalBytes,
    filename: isDirectory ? `${basename}.zip` : basename,
    zipCwd: path.dirname(target),
    zipEntryName: basename,
  };
}

// Upload into an absolute directory chosen in the unified file browser. Mirrors
// resolveUploadTarget but without the workdir confinement, matching the
// browser's whole-filesystem reach. The filename is still sanitised to a bare
// basename so it cannot traverse out of the chosen directory.
function resolveAbsoluteUploadTarget(value, filename) {
  const raw = String(value || '').trim();
  if (!raw || !path.isAbsolute(raw)) {
    throw new FilesystemError('upload path must be absolute', {
      status: 400,
      code: 'FS_PATH_MUST_BE_ABSOLUTE',
    });
  }
  const directory = path.resolve(raw);
  let stat;
  try {
    stat = fs.statSync(directory);
  } catch (_err) {
    throw new FilesystemError('path not found', {
      status: 404,
      code: 'FS_PATH_NOT_FOUND',
    });
  }
  if (!stat.isDirectory()) {
    throw new FilesystemError('upload target is not a directory', {
      status: 400,
      code: 'FS_PATH_NOT_DIRECTORY',
    });
  }
  const rawName = String(filename || '').trim();
  const name = path.basename(rawName);
  if (!name || name === '.' || name === '..' || rawName.includes('/') || rawName.includes('\\')) {
    throw new FilesystemError('invalid upload file name', {
      status: 400,
      code: 'FS_INVALID_FILE_NAME',
    });
  }
  const target = path.resolve(directory, name);
  if (!isInside(directory, target)) {
    throw new FilesystemError('path is outside the target directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  assertPathAllowed(target);
  assertPathAllowed(path.join(fs.realpathSync(directory), name));
  return { directory, target, name, root: directory, realRoot: directory };
}

// Workdir-relative download. Enforces the same size cap as the absolute path:
// a single file by its size, a directory by its uncompressed total.
async function prepareDownload(relativePath, workdir, { maxBytes } = {}) {
  const resolved = resolveExisting(relativePath, workdir);
  if (!resolved.stat.isFile() && !resolved.stat.isDirectory()) {
    throw new FilesystemError('only files and directories can be downloaded', {
      status: 400,
      code: 'FS_UNSUPPORTED_DOWNLOAD',
    });
  }
  const isDirectory = resolved.stat.isDirectory();
  if (isDirectory) assertTreeAllowed(resolved.target);
  const totalBytes = isDirectory
    ? await directorySize(resolved.target, maxBytes)
    : resolved.stat.size;
  if (typeof maxBytes === 'number' && maxBytes > 0 && totalBytes > maxBytes) {
    throw new FilesystemError('download exceeds the size limit', {
      status: 413,
      code: 'FS_DOWNLOAD_TOO_LARGE',
      meta: { totalBytes, maxBytes },
    });
  }
  const basename = path.basename(resolved.target) || 'workdir';
  return {
    ...resolved,
    filename: isDirectory ? `${basename}.zip` : basename,
    isDirectory,
    totalBytes,
    zipCwd: path.dirname(resolved.target),
    zipEntryName: basename,
  };
}

function resolveUploadTarget(relativePath, filename, workdir, { createDirectory = false } = {}) {
  let resolved;
  try {
    resolved = resolveExisting(relativePath, workdir);
  } catch (err) {
    if (!createDirectory || err.code !== 'FS_PATH_NOT_FOUND') throw err;
    const { root, realRoot } = currentRoot(workdir);
    const directory = path.resolve(root, normalizeRelative(relativePath));
    const missing = [];
    let ancestor = directory;
    while (true) {
      try {
        fs.lstatSync(ancestor);
        break;
      } catch (ancestorError) {
        if (ancestorError.code !== 'ENOENT') throw ancestorError;
        missing.push(ancestor);
        ancestor = path.dirname(ancestor);
      }
    }
    const realAncestor = fs.realpathSync(ancestor);
    const realTarget = path.resolve(realAncestor, path.relative(ancestor, directory));
    if (!isInside(realRoot, realTarget)) {
      throw new FilesystemError('path is outside the work directory', {
        status: 403,
        code: 'FS_PATH_OUTSIDE_WORKDIR',
      });
    }
    // Check every directory before mkdir can create any of the missing parents.
    for (const dir of missing) {
      assertPathAllowed(dir);
      assertPathAllowed(path.resolve(realAncestor, path.relative(ancestor, dir)));
    }
    resolved = { root, realRoot, target: directory, realTarget };
  }
  if (resolved.stat && !resolved.stat.isDirectory()) {
    throw new FilesystemError('upload target is not a directory', {
      status: 400,
      code: 'FS_PATH_NOT_DIRECTORY',
    });
  }
  const rawName = String(filename || '').trim();
  const name = path.basename(rawName);
  if (!name || name === '.' || name === '..' || rawName.includes('/') || rawName.includes('\\')) {
    throw new FilesystemError('invalid upload file name', {
      status: 400,
      code: 'FS_INVALID_FILE_NAME',
    });
  }
  const target = path.resolve(resolved.target, name);
  if (!isInside(resolved.root, target)) {
    throw new FilesystemError('path is outside the work directory', {
      status: 403,
      code: 'FS_PATH_OUTSIDE_WORKDIR',
    });
  }
  assertPathAllowed(target);
  assertPathAllowed(path.resolve(resolved.realTarget, name));
  if (!resolved.stat) {
    fs.mkdirSync(resolved.realTarget, { recursive: true });
    resolved = resolveExisting(relativePath, workdir);
  }
  return {
    root: resolved.root,
    realRoot: resolved.realRoot,
    directory: resolved.target,
    target,
    name,
  };
}

function uploadedEntry(root, target) {
  const stat = fs.lstatSync(target);
  return {
    name: path.basename(target),
    path: toApiPath(root, target),
    absolutePath: target,
    type: stat.isDirectory() ? 'directory' : stat.isFile() ? 'file' : 'other',
    size: stat.size,
    modifiedAt: stat.mtime.toISOString(),
  };
}

function uploadTooLargeError() {
  return new FilesystemError('upload exceeds the size limit', {
    status: 413,
    code: 'FS_UPLOAD_TOO_LARGE',
  });
}

// Stream an upload body straight to disk instead of buffering it in memory
// (uploads run up to MAX_UPLOAD_BYTES; a few concurrent buffered ones used to
// spike RSS by hundreds of MB). The bytes land in a fresh temp file next to the
// target ('wx' so we never write through anything pre-existing), then rename
// into place — atomic, and replacing rather than following a symlink at the
// target. Over-limit transfers are cut off mid-stream.
function streamUploadToFile(req, targetPath, maxBytes) {
  const tmpPath = `${targetPath}.upload-${randomUUID()}`;
  return new Promise((resolve, reject) => {
    const out = fs.createWriteStream(tmpPath, { flags: 'wx', mode: 0o644 });
    let received = 0;
    let failed = false;
    const fail = (err) => {
      if (failed) return;
      failed = true;
      req.unpipe(out);
      out.destroy();
      fs.unlink(tmpPath, () => {});
      reject(err);
    };
    req.on('error', fail);
    req.on('aborted', () => fail(new Error('upload aborted')));
    out.on('error', fail);
    req.on('data', (chunk) => {
      received += chunk.length;
      if (received > maxBytes) fail(uploadTooLargeError());
    });
    out.on('finish', () => {
      if (failed) return;
      try {
        fs.renameSync(tmpPath, targetPath);
        resolve(received);
      } catch (err) {
        fail(err);
      }
    });
    req.pipe(out);
  });
}

function sendFilesystemError(res, err) {
  if (err instanceof FilesystemError) {
    return res.status(err.status || 400).json({
      error: err.message,
      code: err.code,
    });
  }
  return res.status(500).json({ error: err.message });
}

function attachmentHeader(filename) {
  const fallback = String(filename || 'download')
    .replace(/[^\x20-\x7e]/g, '_')
    .replace(/["\\]/g, '_');
  return `attachment; filename="${fallback}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}

function safeDownloadName(value, fallback = 'download') {
  const cleaned = String(value || '')
    .replace(/[^\w.-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  return cleaned || fallback;
}

function cleanupTempZip(zipPath) {
  fs.unlink(zipPath, () => {
    fs.rm(path.dirname(zipPath), { recursive: true, force: true }, () => {});
  });
}

function sendWindowsDirectoryZip(download, res) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-zip-'));
  const tempZip = path.join(tempDir, `${randomUUID()}.zip`);
  const sourcePath = path.join(download.zipCwd, download.zipEntryName);
  const powershell = process.env.POWERSHELL_BIN || 'powershell.exe';
  const child = spawn(
    powershell,
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Compress-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force',
      sourcePath,
      tempZip,
    ],
    { windowsHide: true },
  );
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  child.on('error', (err) => {
    cleanupTempZip(tempZip);
    if (!res.headersSent) {
      return res.status(500).json({ error: `zip failed: ${err.message}` });
    }
    return res.destroy(err);
  });
  child.on('close', (code) => {
    if (code !== 0) {
      cleanupTempZip(tempZip);
      const message = stderr.trim() || `zip exited with code ${code}`;
      if (!res.headersSent) {
        return res.status(500).json({ error: message });
      }
      return res.destroy(new Error(message));
    }
    return res.download(tempZip, download.filename, (err) => {
      cleanupTempZip(tempZip);
      if (err && !res.headersSent) {
        return sendFilesystemError(res, err);
      }
      return undefined;
    });
  });
}

function sendUnixDirectoryZip(download, res, maxBytes) {
  const child = spawn('zip', ['-r', '-q', '-y', '-', download.zipEntryName], {
    cwd: download.zipCwd,
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  child.on('error', (err) => {
    if (!res.headersSent) {
      return res.status(500).json({ error: `zip failed: ${err.message}` });
    }
    return res.destroy(err);
  });
  child.on('close', (code) => {
    if (code !== 0 && !res.destroyed) {
      const message = stderr.trim() || `zip exited with code ${code}`;
      if (!res.headersSent) {
        return res.status(500).json({ error: message });
      }
      return res.destroy(new Error(message));
    }
    return undefined;
  });
  res.setHeader('Content-Type', 'application/zip');
  res.setHeader('Content-Disposition', attachmentHeader(download.filename));
  // Defence in depth: the pre-flight size check uses the uncompressed total, so a
  // compliant zip is always smaller. If the stream ever exceeds the cap anyway
  // (e.g. files grew mid-zip), abort rather than blow the tunnel's budget.
  let sentBytes = 0;
  child.stdout.on('data', (chunk) => {
    sentBytes += chunk.length;
    if (sentBytes > maxBytes) {
      child.kill('SIGKILL');
      res.destroy();
    }
  });
  return child.stdout.pipe(res);
}

function sendDirectoryZip(download, res, maxBytes) {
  if (process.platform === 'win32') {
    return sendWindowsDirectoryZip(download, res);
  }
  return sendUnixDirectoryZip(download, res, maxBytes);
}

module.exports = {
  listAbsoluteDirectory,
  prepareDownload,
  prepareDownloadAbsolute,
  resolveUploadTarget,
  resolveAbsoluteUploadTarget,
  safeDownloadName,
  sendDirectoryZip,
  sendFilesystemError,
  streamUploadToFile,
  uploadedEntry,
};
