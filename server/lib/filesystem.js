'use strict';

const fs = require('fs');
const path = require('path');

const { getDefaultWorkdir, ensureWorkdirExists } = require('./workdir');

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
  return {
    root,
    realRoot,
    target,
    realTarget,
    relative: toApiPath(root, target),
    stat,
  };
}

function entryFor(root, target, dirent, { absolutePaths = false } = {}) {
  const stat = fs.lstatSync(target);
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

function visibleDirents(target, { showHidden = false } = {}) {
  return fs
    .readdirSync(target, { withFileTypes: true })
    .filter((dirent) => showHidden || !dirent.name.startsWith('.'));
}

function sortEntries(entries) {
  return entries.sort((a, b) => {
    if (a.type === 'directory' && b.type !== 'directory') return -1;
    if (a.type !== 'directory' && b.type === 'directory') return 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
  });
}

function listDirectory(relativePath, { showHidden = false, workdir } = {}) {
  const resolved = resolveExisting(relativePath, workdir);
  if (!resolved.stat.isDirectory()) {
    throw new FilesystemError('path is not a directory', {
      status: 400,
      code: 'FS_PATH_NOT_DIRECTORY',
    });
  }
  const entries = sortEntries(
    visibleDirents(resolved.target, { showHidden }).map((dirent) =>
      entryFor(resolved.root, path.join(resolved.target, dirent.name), dirent),
    ),
  );
  const parentPath =
    resolved.target === resolved.root
      ? null
      : toApiPath(resolved.root, path.dirname(resolved.target));
  return {
    root: resolved.root,
    path: resolved.relative,
    absolutePath: resolved.target,
    parentPath,
    entries,
  };
}

function listAbsoluteDirectory(value, { showHidden = false, fallbackDir } = {}) {
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
    stat = fs.statSync(target);
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
  const root = path.parse(target).root;
  const entries = sortEntries(
    visibleDirents(target, { showHidden }).map((dirent) =>
      entryFor(root, path.join(target, dirent.name), dirent, {
        absolutePaths: true,
      }),
    ),
  );
  return {
    root,
    path: target,
    absolutePath: target,
    parentPath: target === root ? null : path.dirname(target),
    entries,
  };
}

// Recursively sum the size of every regular file under `dir`. Symlinks are
// skipped so the walk cannot loop or escape via a linked directory. Used to
// reject directory (zip) downloads before we start streaming, since the tunnel
// has a hard size budget and a half-sent zip cannot become a clean error.
function directorySize(dir) {
  let total = 0;
  const stack = [dir];
  while (stack.length) {
    const current = stack.pop();
    let dirents;
    try {
      dirents = fs.readdirSync(current, { withFileTypes: true });
    } catch (_err) {
      continue;
    }
    for (const dirent of dirents) {
      const full = path.join(current, dirent.name);
      let stat;
      try {
        stat = fs.lstatSync(full);
      } catch (_err) {
        continue;
      }
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) {
        stack.push(full);
      } else if (stat.isFile()) {
        total += stat.size;
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
function prepareDownloadAbsolute(value, { maxBytes } = {}) {
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
    stat = fs.statSync(target);
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
  const totalBytes = isDirectory ? directorySize(target) : stat.size;
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
  return { directory, target, name, root: directory, realRoot: directory };
}

function prepareDownload(relativePath, workdir) {
  const resolved = resolveExisting(relativePath, workdir);
  if (!resolved.stat.isFile() && !resolved.stat.isDirectory()) {
    throw new FilesystemError('only files and directories can be downloaded', {
      status: 400,
      code: 'FS_UNSUPPORTED_DOWNLOAD',
    });
  }
  const basename = path.basename(resolved.target) || 'workdir';
  return {
    ...resolved,
    filename: resolved.stat.isDirectory() ? `${basename}.zip` : basename,
    isDirectory: resolved.stat.isDirectory(),
    zipCwd: path.dirname(resolved.target),
    zipEntryName: basename,
  };
}

function resolveUploadTarget(relativePath, filename, workdir) {
  const resolved = resolveExisting(relativePath, workdir);
  if (!resolved.stat.isDirectory()) {
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

module.exports = {
  FilesystemError,
  listDirectory,
  listAbsoluteDirectory,
  prepareDownload,
  prepareDownloadAbsolute,
  resolveUploadTarget,
  resolveAbsoluteUploadTarget,
  uploadedEntry,
};
