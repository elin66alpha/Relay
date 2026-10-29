'use strict';

const fs = require('node:fs');
const path = require('node:path');

function checkDocs(root) {
  const files = ['README.md', 'README.zh-CN.md', 'AGENTS.md', 'ENGINEERING.md'];
  const docs = path.join(root, 'docs');
  for (const entry of fs.readdirSync(docs)) {
    if (entry.endsWith('.md')) files.push(`docs/${entry}`);
  }
  const errors = [];
  for (const file of files) {
    const source = path.join(root, file);
    let inFence = false;
    for (const [index, line] of fs.readFileSync(source, 'utf8').split('\n').entries()) {
      if (/^\s*```/.test(line)) { inFence = !inFence; continue; }
      if (inFence) continue;
      for (const match of line.matchAll(/\]\(([^)\s]+)(?:\s+['"][^)]*['"])?\)/g)) {
        const target = match[1];
        if (/^(?:[a-z]+:|\/\/)/i.test(target)) continue;
        const [name, fragment] = target.split('#', 2).map(decodeURIComponent);
        const resolved = name ? path.resolve(path.dirname(source), name) : source;
        if (!fs.existsSync(resolved)) {
          errors.push(`${file}:${index + 1}: missing ${target}`);
        } else if (fragment && resolved.endsWith('.md')) {
          const headings = fs.readFileSync(resolved, 'utf8').split('\n')
            .filter((text) => /^#{1,6}\s/.test(text))
            .map((text) => text.replace(/^#{1,6}\s+/, '').trim().toLowerCase()
              .replace(/[^\p{L}\p{N}_\-\s]/gu, '').replace(/\s/g, '-'));
          if (!headings.includes(fragment.toLowerCase())) errors.push(`${file}:${index + 1}: missing ${target}`);
        }
      }
    }
  }
  return errors;
}

if (require.main === module) {
  const errors = checkDocs(path.resolve(__dirname, '../..'));
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exitCode = 1;
  } else console.log('Local documentation links resolve.');
}

module.exports = { checkDocs };
