import { cpSync, mkdirSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = join(root, 'src/public');
const dest = join(root, 'dist/public');

mkdirSync(dest, { recursive: true });
cpSync(src, dest, { recursive: true });
console.log('copied src/public -> dist/public');
