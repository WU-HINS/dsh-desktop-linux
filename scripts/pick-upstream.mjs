#!/usr/bin/env node
// Compare the newest upstream DeepSeek Harness release with the tag tracked by PKGBUILD.
// Usage: node scripts/pick-upstream.mjs <upstream-tags-file> <current-tag>
// Prints shell-friendly KEY=VALUE lines; write them to $GITHUB_OUTPUT when present.
import { readFileSync, appendFileSync } from 'node:fs'

const [tagsFile, currentTag = ''] = process.argv.slice(2)
const PREFIX = /^dsh-v(.+)$/u

const parse = (version) => {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/u.exec(version)
  if (match === null) return undefined
  return {
    numbers: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4] === undefined ? [] : match[4].split('.'),
  }
}

const compareIdentifiers = (left, right) => {
  const numeric = /^\d+$/u
  if (numeric.test(left) && numeric.test(right)) return Number(left) - Number(right)
  if (numeric.test(left)) return -1
  if (numeric.test(right)) return 1
  return left < right ? -1 : left > right ? 1 : 0
}

const compare = (left, right) => {
  for (let index = 0; index < 3; index += 1) {
    const delta = left.numbers[index] - right.numbers[index]
    if (delta !== 0) return delta
  }
  if (left.prerelease.length === 0 && right.prerelease.length === 0) return 0
  if (left.prerelease.length === 0) return 1
  if (right.prerelease.length === 0) return -1
  const length = Math.max(left.prerelease.length, right.prerelease.length)
  for (let index = 0; index < length; index += 1) {
    const leftPart = left.prerelease[index]
    const rightPart = right.prerelease[index]
    if (leftPart === undefined) return -1
    if (rightPart === undefined) return 1
    const delta = compareIdentifiers(leftPart, rightPart)
    if (delta !== 0) return delta
  }
  return 0
}

const upstream = readFileSync(tagsFile, 'utf8')
  .split('\n')
  .map((line) => line.trim())
  .filter(Boolean)
  .map((tag) => {
    const match = PREFIX.exec(tag)
    const parsed = match === null ? undefined : parse(match[1])
    return parsed === undefined ? undefined : { tag, version: match[1], parsed }
  })
  .filter((entry) => entry !== undefined)
  .sort((left, right) => compare(right.parsed, left.parsed))

const newest = upstream[0]
const currentMatch = /^dsh-v(.+)$/u.exec(currentTag.trim())
const current = currentMatch === null ? undefined : parse(currentMatch[1])

const shouldBump = newest !== undefined && (current === undefined || compare(newest.parsed, current) > 0)
// Release tags in this repository drop the prerelease dash: 0.2.2-rc.5 -> v0.2.2rc5.
const releaseTag = newest === undefined ? '' : `v${newest.version.replace(/-/gu, '')}`

const lines = [
  `should_bump=${String(shouldBump)}`,
  `tag=${newest?.tag ?? ''}`,
  `version=${newest?.version ?? ''}`,
  `release_tag=${releaseTag}`,
]
const target = process.env.GITHUB_OUTPUT
if (target) appendFileSync(target, `${lines.join('\n')}\n`)
else console.log(lines.join('\n'))
