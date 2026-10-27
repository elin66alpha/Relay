'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const {
  averageTemperatures,
  parseLinuxMounts,
  parseLspciGpus,
  readHwmonTemperatures,
} = require('../lib/machine-info');

test('parseLspciGpus keeps display controllers without the revision', () => {
  const text = [
    '00:02.0 VGA compatible controller: Intel Corporation HD Graphics 530 (rev 06)',
    '01:00.0 3D controller: NVIDIA Corporation GP106M [GeForce GTX 1060 Mobile] (rev a1)',
    '3d:00.0 Non-Volatile memory controller: Samsung Electronics Co Ltd SM961',
  ].join('\n');
  assert.deepEqual(parseLspciGpus(text), [
    'Intel HD Graphics 530',
    'NVIDIA GP106M [GeForce GTX 1060 Mobile]',
  ]);
});

test('temperatures average every sensor of a part and drop other chips', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-hwmon-'));
  const chip = (dir, name, files) => {
    fs.mkdirSync(path.join(root, dir));
    fs.writeFileSync(path.join(root, dir, 'name'), `${name}\n`);
    for (const [file, value] of Object.entries(files)) {
      fs.writeFileSync(path.join(root, dir, file), `${value}\n`);
    }
  };
  chip('hwmon1', 'acpitz_0', { temp1_input: 28000 });
  chip('hwmon2', 'acpitz_1', { temp1_input: 30000 });
  chip('hwmon3', 'coretemp', {
    temp1_input: 49000,
    temp1_label: 'Package id 0',
    temp2_input: 48000,
    temp3_input: 0,
  });
  chip('hwmon4', 'pch_skylake', { temp1_input: 57000 });
  const readings = await readHwmonTemperatures(root);
  assert.deepEqual(
    averageTemperatures([...readings, { key: 'gpu', celsius: 43 }]),
    [
      { key: 'mainboard', label: 'Mainboard', celsius: 29 },
      { key: 'cpu', label: 'CPU', celsius: 48.5 },
      { key: 'gpu', label: 'GPU', celsius: 43 },
    ],
  );
  assert.deepEqual(await readHwmonTemperatures(path.join(root, 'missing')), []);
  fs.rmSync(root, { recursive: true, force: true });
});

test('parseLinuxMounts lists each disk once without snap images', () => {
  const text = [
    '/dev/nvme0n1p2 / ext4 rw 0 0',
    'proc /proc proc rw 0 0',
    '/dev/loop0 /snap/core22/1 squashfs ro 0 0',
    '/dev/sda1 /mnt/My\\040Disk ntfs3 rw 0 0',
    '/dev/nvme0n1p2 /var/snap/bind ext4 rw 0 0',
  ].join('\n');
  assert.deepEqual(parseLinuxMounts(text), ['/', '/mnt/My Disk']);
});
