#!/usr/bin/env node
// Write latest.json describing the artifacts collected for one release.
import { createHash } from 'node:crypto'
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [directory = 'dist', tag = '', version = ''] = process.argv.slice(2)
const extensions = /\.(AppImage|deb|rpm|pkg\.tar\.zst)$/u

const assets = readdirSync(directory)
  .filter((name) => extensions.test(name))
  .sort()
  .map((name) => {
    const path = join(directory, name)
    const bytes = readFileSync(path)
    return {
      name,
      size: statSync(path).size,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      signatures: readdirSync(directory).includes(`${name}.asc`) ? [`${name}.asc`] : [],
    }
  })

const manifest = {
  tag,
  version,
  releasedAt: new Date().toISOString(),
  upstream: 'https://github.com/deepseek-ai/deepseek-harness',
  base: 'https://github.com/ffyfox/dsh-desktop-linux',
  assets,
}

writeFileSync(join(directory, 'latest.json'), `${JSON.stringify(manifest, null, 2)}\n`)
console.log(`latest.json: ${assets.length} asset(s)`)
