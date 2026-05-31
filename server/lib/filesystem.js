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
  resolveUploadTarget,
  uploadedEntry,
};
