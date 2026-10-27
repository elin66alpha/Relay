'use strict';

const { execFile } = require('child_process');
const fs = require('fs/promises');
const os = require('os');
const path = require('path');

// The parts the machine page shows, in order, and the hwmon chips that measure
// each; other chips (chipset, Wi-Fi) are left out.
const PARTS = [
  ['mainboard', 'Mainboard', ['acpitz']],
  ['ssd', 'SSD', ['nvme']],
  ['cpu', 'CPU', ['coretemp', 'k10temp', 'zenpower', 'cpu_thermal']],
  ['gpu', 'GPU', ['amdgpu', 'nouveau', 'radeon']],
];

function run(bin, args) {
  return new Promise((resolve) => {
    execFile(bin, args, { timeout: 3000, windowsHide: true }, (err, stdout) => {
      resolve(err ? '' : String(stdout));
    });
  });
}

function parseLspciGpus(text) {
  const gpus = [];
  for (const line of String(text).split(/\r?\n/)) {
    const match = line.match(
      /^\S+\s+(?:VGA compatible controller|3D controller|Display controller):\s*(.+?)(?:\s+\(rev [^)]+\))?$/,
    );
    if (match) gpus.push(match[1].replace(' Corporation', ''));
  }
  return gpus;
}

async function gpuNames() {
  if (process.platform === 'linux') {
    return parseLspciGpus(await run('lspci', []));
  }
  if (process.platform === 'darwin') {
    const text = await run('system_profiler', ['SPDisplaysDataType']);
    return [...text.matchAll(/Chipset Model:\s*(.+)/g)].map((m) => m[1].trim());
  }
  if (process.platform === 'win32') {
    const text = await run('powershell', [
      '-NoProfile',
      '-Command',
      '(Get-CimInstance Win32_VideoController).Name',
    ]);
    return text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  }
  return [];
}

async function readText(file) {
  try {
    return (await fs.readFile(file, 'utf8')).trim();
  } catch (_err) {
    return '';
  }
}

// shortcut: only Linux hwmon and nvidia-smi are read; macOS and Windows need
// root for CPU sensors, so they show GPU temperatures from nvidia-smi or none.
async function readHwmonTemperatures(root = '/sys/class/hwmon') {
  let chips;
  try {
    chips = await fs.readdir(root);
  } catch (_err) {
    return [];
  }
  const readings = [];
  for (const chip of chips) {
    const dir = path.join(root, chip);
    const name = (await readText(path.join(dir, 'name'))).replace(/_\d+$/, '');
    const part = PARTS.find(([, , names]) => names.includes(name));
    if (!part) continue;
    let files;
    try {
      files = await fs.readdir(dir);
    } catch (_err) {
      continue;
    }
    for (const input of files.filter((file) => /^temp\d+_input$/.test(file))) {
      const milli = Number(await readText(path.join(dir, input)));
      if (Number.isFinite(milli) && milli > 0) {
        readings.push({ key: part[0], celsius: milli / 1000 });
      }
    }
  }
  return readings;
}

async function nvidiaTemperatures() {
  const text = await run('nvidia-smi', [
    '--query-gpu=temperature.gpu',
    '--format=csv,noheader,nounits',
  ]);
  return text
    .split(/\r?\n/)
    .filter((line) => line.trim() && Number.isFinite(Number(line)))
    .map((line) => ({ key: 'gpu', celsius: Number(line) }));
}

// One reading per part, the average of all its sensors (CPU package and cores,
// both ACPI zones, every GPU), in PARTS order.
function averageTemperatures(readings) {
  const averaged = [];
  for (const [key, label] of PARTS) {
    const values = readings.filter((r) => r.key === key).map((r) => r.celsius);
    if (values.length === 0) continue;
    const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
    averaged.push({ key, label, celsius: Math.round(mean * 10) / 10 });
  }
  return averaged;
}

// Each block device once (bind mounts repeat it), without snap loop images.
// shortcut: pools not backed by a /dev node (ZFS) are not listed; read
// `zfs list` if a host needs them.
function parseLinuxMounts(text) {
  const seen = new Set();
  const mounts = [];
  for (const line of String(text).split('\n')) {
    const [source, target] = line.split(' ');
    if (!source || !source.startsWith('/dev/') || source.startsWith('/dev/loop')) {
      continue;
    }
    if (seen.has(source)) continue;
    seen.add(source);
    mounts.push(
      target.replace(/\\(\d{3})/g, (_, octal) =>
        String.fromCharCode(parseInt(octal, 8)),
      ),
    );
  }
  return mounts;
}

async function mountPoints() {
  if (process.platform === 'linux') {
    return parseLinuxMounts(await readText('/proc/mounts'));
  }
  if (process.platform === 'win32') {
    return [...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'].map((letter) => `${letter}:\\`);
  }
  try {
    const volumes = await fs.readdir('/Volumes');
    return ['/', ...volumes.map((name) => path.join('/Volumes', name))];
  } catch (_err) {
    return ['/'];
  }
}

async function storageDisks() {
  const seen = new Set();
  const disks = [];
  for (const mount of await mountPoints()) {
    try {
      // macOS lists the startup disk again as a link under /Volumes.
      const real = await fs.realpath(mount);
      if (seen.has(real)) continue;
      seen.add(real);
      const stat = await fs.statfs(mount);
      if (stat.blocks === 0) continue;
      disks.push({
        mount,
        usedBytes: (stat.blocks - stat.bfree) * stat.bsize,
        totalBytes: stat.blocks * stat.bsize,
      });
    } catch (_err) {
      // An empty drive letter or a volume this user cannot read.
    }
  }
  return disks;
}

let hardware = null;

function machineHardware() {
  // The hardware does not change while the backend runs, so probe it once.
  hardware ||= gpuNames().then((gpus) => ({
    cpu: { model: (os.cpus()[0] || {}).model || '', cores: os.cpus().length },
    memoryBytes: os.totalmem(),
    gpus,
  }));
  return hardware;
}

async function machineInfo() {
  const [base, disks, hwmon, nvidia] = await Promise.all([
    machineHardware(),
    storageDisks(),
    readHwmonTemperatures(),
    nvidiaTemperatures(),
  ]);
  return {
    ok: true,
    hostname: os.hostname(),
    ...base,
    disks,
    temperatures: averageTemperatures([...hwmon, ...nvidia]),
  };
}

module.exports = {
  averageTemperatures,
  machineInfo,
  parseLinuxMounts,
  parseLspciGpus,
  readHwmonTemperatures,
};
