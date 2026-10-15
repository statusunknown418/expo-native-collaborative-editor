#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');

const SUBTARGETS = ['plugin', 'cli', 'utils', 'scripts'];
const [, , target] = process.argv;

if (target && SUBTARGETS.includes(target)) {
  fs.rmSync(path.join(process.cwd(), target, 'build'), { force: true, recursive: true });
} else {
  fs.rmSync(path.join(process.cwd(), 'build'), { force: true, recursive: true });
}
