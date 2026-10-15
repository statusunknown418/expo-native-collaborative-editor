#!/usr/bin/env node
const { spawnSyncWithAutoShell } = require('./util');
const fs = require('node:fs');
const path = require('node:path');

const SUBTARGETS = ['plugin', 'cli', 'utils', 'scripts'];

function run(cmd, args = []) {
  const result = spawnSyncWithAutoShell(cmd, args, { stdio: 'inherit' });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

// Clean and build main
fs.rmSync(path.join(process.cwd(), 'build'), { force: true, recursive: true });
run('tsc');

// Clean and build any existing subtargets
for (const target of SUBTARGETS) {
  const targetDir = path.join(process.cwd(), target);
  if (fs.existsSync(targetDir) && fs.existsSync(path.join(targetDir, 'tsconfig.json'))) {
    console.log(`Building ${target}`);
    fs.rmSync(path.join(targetDir, 'build'), { force: true, recursive: true });
    run('tsc', ['--build', targetDir]);
  }
}
