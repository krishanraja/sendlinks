#!/usr/bin/env node
/**
 * Session closeout: every session that changes a repository leaves its
 * status, next step and North Star check current in NOW.md, without Krish
 * asking (Ruling, Krish, 2026-10-22).
 *
 * One file, two callers, the same bytes in both places:
 *
 *   - Claude Code's Stop hook. The repository administration publisher
 *     delivers this file as `.claude/hooks/harness-closeout.mjs` and registers
 *     it in `.claude/settings.json`. When a turn ends with committed product
 *     work and NOW.md untouched, the hook blocks once with the closeout steps.
 *     A second stop in the same turn (stop_hook_active) always passes, so the
 *     hook can never trap a session.
 *   - The `closeout` job in `.github/workflows/harness-repository-context.yml`
 *     on every pull request: `--ci --base <sha> --head <sha>`. This is what
 *     holds Codex and any other client to the same rule.
 *
 * The rule. A range of commits that changes anything but NOW.md, the history
 * archive or a harness-generated file must close out, one of two ways:
 *
 *   - a closeout note, now-notes/YYYY-MM-DD-<slug>.md, with three lines:
 *
 *       Status: <what is true now that this work changed>
 *       Next: <the single next action>
 *       North Star check (YYYY-MM-DD): holds.
 *
 *     and optionally `Changed: <the why, for "What changed recently">`. When
 *     the note reaches main, the `fold` job of the same check workflow runs
 *     this file with --fold, which writes it into NOW.md and deletes it. Two
 *     pull requests therefore never edit NOW.md at once, and never conflict
 *     over it (Ruling, Krish, 2026-10-28).
 *   - or, as before, NOW.md itself: bump its `as_of` and carry one line under
 *     "What is next and what is waiting on Krish":
 *
 *       - North Star check (YYYY-MM-DD): holds.
 *       - North Star check (YYYY-MM-DD): recalibration proposed. <why>
 *
 * Either way the check is dated no earlier than the work began: the session's
 * first commit, so merging main into an open pull request never forces a new
 * date. docs/NORTH_STAR.md changes only with
 * a `Ruling (Krish, YYYY-MM-DD)` line in a commit body or the pull request.
 * Commits written by the harness's own automation (docs(steward), docs(harness),
 * docs(canon), docs(closeout), chore(audit)) are exempt, as is a range carrying
 * `Closeout: not needed, <reason>`.
 *
 * Dependency-free on purpose: it runs inside any repository, in any session.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const NOW = 'NOW.md'
export const NORTH_STAR = 'docs/NORTH_STAR.md'
export const WAITING = 'What is next and what is waiting on Krish'
export const AUTOMATION = /^(docs\((steward|harness|canon|closeout)\)|chore\((heartbeat|brain|audit)\)):/
// What each automation may touch. A commit that claims an automation subject
// but touches anything else is a session's own work, so the subject cannot be
// used to skip the rule.
const AUTOMATION_SCOPE = {
  steward: (p) => /\.md$/i.test(p) && p !== NORTH_STAR,
  harness: (p) => ['AGENTS.md', 'CLAUDE.md', 'docs/HARNESS_CONTEXT.md', SETTINGS, ...PUBLISHER_FILES].includes(p),
  canon: (p) => ['AGENTS.md', 'CLAUDE.md'].includes(p),
  closeout: (p) => p === NOW || NOTE.test(p),
  heartbeat: (p) => /^state\//.test(p),
  brain: (p) => /^(brain|state)\//.test(p),
  audit: (p) => /^state\/now-audit\//.test(p),
}
export const SETTINGS = '.claude/settings.json'
// Owned outright by the publisher. In .claude/settings.json it owns only its one
// Stop hook entry; every other setting there is the repository's to change.
export const PUBLISHER_FILES = ['.github/workflows/harness-repository-context.yml', '.claude/hooks/harness-closeout.mjs']
export const isAutomation = (c) => { const m = c.subject.match(AUTOMATION); return !!m && c.files.every(AUTOMATION_SCOPE[m[2] || m[3]]) }
export const DEPENDENCY_BOTS = new Set(['dependabot[bot]', 'renovate[bot]'])
export const SKIP = /^Closeout: not needed, \S.{7,}/m
export const RULING = /Ruling \(Krish, \d{4}-\d{2}-\d{2}\)/
const CHECK_LINE = /^- North Star check \((\d{4}-\d{2}-\d{2})\): (holds\.|recalibration proposed\.\s+\S.*)$/
export const NOTES = 'now-notes'
export const NOTE = /^now-notes\/(\d{4}-\d{2}-\d{2})-[a-z0-9][a-z0-9-]{0,60}\.md$/

/**
 * Work a reader of NOW.md could need to know about: anything but NOW.md itself,
 * the history archive and files the harness generates. Plan and handoff
 * documents count, because a session that rewrites a plan has moved the
 * repository's state as surely as one that changes code.
 */
export const NOT_WORK = /^(NOW\.md|now-notes\/.*|docs\/history\/.*|docs\/HARNESS_CONTEXT\.md)$/
export const isProduct = (path) => !NOT_WORK.test(path)

/** The section body under a `## ` heading, or null. */
export function section(text, heading) {
  const lines = String(text || '').split(/\r?\n/)
  const at = lines.findIndex((l) => l.startsWith(`## ${heading}`))
  if (at < 0) return null
  const end = lines.findIndex((l, i) => i > at && l.startsWith('## '))
  return lines.slice(at + 1, end < 0 ? undefined : end).join('\n')
}

/** The North Star check line of a NOW.md: { date, verdict, proposal } or null. */
export function northStarCheck(text) {
  const body = section(text, WAITING)
  if (body == null) return null
  const hits = body.split(/\r?\n/).map((l) => l.trim().match(CHECK_LINE)).filter(Boolean)
  if (hits.length !== 1) return hits.length ? { date: null, verdict: 'duplicate', proposal: null } : null
  const [, date, rest] = hits[0]
  return rest === 'holds.' ? { date, verdict: 'holds', proposal: null } : { date, verdict: 'recalibration_proposed', proposal: rest.replace(/^recalibration proposed\.\s+/, '') }
}

export const asOf = (text) => String(text || '').match(/^as_of:\s*(\d{4}-\d{2}-\d{2})\s*$/m)?.[1] ?? null

const LABELS = ['Status', 'Changed', 'Next']
const NOTE_CHECK = /^North Star check \((\d{4}-\d{2}-\d{2})\): (holds\.|recalibration proposed\.\s+\S.*)$/

/**
 * A closeout note, parsed: { date, status, changed, next, check, problems }.
 * Each label starts a line; its text runs on until the next label or a blank
 * line. Anything else in the note is a problem, so a note can only say what
 * the fold knows where to put.
 */
export function parseNote(path, text) {
  const date = path.match(NOTE)?.[1] ?? null
  const note = { path, date, status: null, changed: null, next: null, check: null, problems: [] }
  if (!date) { note.problems.push(`${path} is not named ${NOTES}/YYYY-MM-DD-<slug>.md (lowercase letters, digits and hyphens).`); return note }
  let field = null
  for (const raw of String(text ?? '').split(/\r?\n/)) {
    const line = raw.trim()
    if (!line) { field = null; continue }
    const label = LABELS.find((l) => line.startsWith(`${l}:`))
    const check = line.match(NOTE_CHECK)
    if (label) { field = label.toLowerCase(); note[field] = line.slice(label.length + 1).trim() }
    else if (check) { field = null; note.check = { date: check[1], text: line } }
    else if (field) note[field] = `${note[field]} ${line}`.trim()
    else note.problems.push(`${path} has a line the fold cannot place: "${line.slice(0, 60)}". Use only Status:, Changed:, Next: and the North Star check line.`)
  }
  if (!note.status || note.status.length < 20) note.problems.push(`${path} needs "Status: <what is true now that this work changed>" (a sentence, not a word).`)
  if (!note.next || note.next.length < 5) note.problems.push(`${path} needs "Next: <the single next action>".`)
  if (!note.check) note.problems.push(`${path} needs one line "North Star check (${date}): holds." or "...: recalibration proposed. <why>".`)
  if (/\u2014/.test(String(text))) note.problems.push(`${path} contains an em dash; NOW.md never does.`)
  return note
}

/**
 * The decision, as data. `commits` are the range's own commits, oldest first,
 * each { subject, body, files }. `pending` are uncommitted paths (the hook only).
 * Returns { ok, problems, reason }.
 */
export function evaluate({ commits = [], body = '', author = '', nowText = null, nowExists = false, settingsText = null, notes = {}, since = null, today }) {
  const own = commits.filter((c) => !isAutomation(c))
  const messages = [body, ...own.map((c) => `${c.subject}\n${c.body}`)].join('\n')
  // Only dependency bots are exempt by author: their pull requests change no
  // status and cannot write NOW.md. Every other automation, the publisher
  // included, is exempt only by its own commit subjects, commit by commit.
  if (DEPENDENCY_BOTS.has(author)) return { ok: true, problems: [], reason: 'dependency update' }
  if (!own.length) return { ok: true, problems: [], reason: 'no session commits' }
  const files = new Set(own.flatMap((c) => c.files))
  const problems = []
  const touched = PUBLISHER_FILES.filter((p) => files.has(p))
  if (touched.length) problems.push(`${touched.join(', ')} belong to the harness's repository administration publisher. Change them in krishanraja/ai-harness, never here; the publisher delivers them.`)
  if (files.has(SETTINGS) && settingsText != null && !settingsText.includes('harness-closeout.mjs')) problems.push(`${SETTINGS} no longer registers the harness closeout hook. Keep its Stop entry; every other setting is this repository's to change.`)
  if (files.has(NORTH_STAR) && !RULING.test(messages)) problems.push(`${NORTH_STAR} changed without a "Ruling (Krish, YYYY-MM-DD): ..." line. Only Krish changes a North Star: revert it and propose the change in NOW.md instead.`)
  // The notes this range leaves on its head. A note it deleted is not a closeout.
  const noteFiles = [...files].filter((p) => NOTE.test(p) && notes[p] != null).sort()
  // A stated reason excuses an untouched NOW.md, never a malformed one.
  if (SKIP.test(messages) && !files.has(NOW) && !noteFiles.length) return { ok: !problems.length, problems, reason: 'closeout not needed, by the stated reason' }
  if (![...files].some(isProduct) && !noteFiles.length) return { ok: !problems.length, problems, reason: 'nothing a reader of NOW.md needs changed' }
  // The work began with its first own commit, not with the base: merging main
  // into an open pull request moves the base, never the start of the work.
  const began = own.map((c) => c.date).filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d || '')).sort()[0]
  const floor = began || since || today
  for (const path of noteFiles) {
    const note = parseNote(path, notes[path])
    problems.push(...note.problems)
    if (note.date && note.date < floor) problems.push(`${path} is dated ${note.date}, before this work began (${floor}). Name it for today, ${today}.`)
    if (note.check && note.check.date < floor) problems.push(`The North Star check in ${path} is dated ${note.check.date}, before this work began. Re-read ${NORTH_STAR} and date the line ${today}.`)
  }
  if (!nowExists) problems.push(`${NOW} does not exist. Create it from the docs steward schema (ai-harness docs/steward/SCHEMA.md) so the repository says where it is.`)
  else if (!files.has(NOW) && noteFiles.length) { /* the note is the closeout; the fold writes NOW.md on main */ }
  else if (!files.has(NOW)) problems.push(`Product files changed but neither ${NOW} nor a closeout note did. Write ${NOTES}/${today}-<slug>.md with "Status:", "Next:" and the North Star check line so the next session starts from the truth.`)
  else {
    const stamp = asOf(nowText)
    if (!stamp || stamp < floor) problems.push(`${NOW} frontmatter as_of is ${stamp || 'missing'}; set it (and the "Where it is right now (as of ...)" heading) to the date of this work, ${today}.`)
    const check = northStarCheck(nowText)
    if (!check) problems.push(`${NOW} has no North Star check line under "${WAITING}". Re-read ${NORTH_STAR} and add exactly one: "- North Star check (${today}): holds." or "- North Star check (${today}): recalibration proposed. <why>".`)
    else if (check.verdict === 'duplicate') problems.push(`${NOW} has more than one North Star check line; keep exactly one, the current one.`)
    else if (check.date < floor) problems.push(`The North Star check in ${NOW} is dated ${check.date}, before this work began. Re-read ${NORTH_STAR} and date the line ${today}.`)
  }
  return { ok: !problems.length, problems, reason: problems.length ? 'closeout incomplete' : 'closed out' }
}

export function instructions(problems, today) {
  return [
    'Before you finish, close out this session (harness contract, "Session closeout"):',
    ...problems.map((p) => `- ${p}`),
    '',
    `How: write ${NOTES}/${today}-<slug>.md with three lines, "Status: <what is true now that this work changed>", "Next: <the single next action>" and "North Star check (${today}): holds." (or "...: recalibration proposed. <why>"), plus "Changed: <the why>" if it belongs in "What changed recently". Do not edit ${NOW}: the note is folded into it when it reaches main, so pull requests never conflict over it. Never edit ${NORTH_STAR}: a recalibration is Krish's call, so propose it in the note. Commit and push with the work.`,
    'If nothing in this work changes what a reader of NOW.md needs, add the commit body line "Closeout: not needed, <reason>".',
  ].join('\n')
}

// ------------------------------------------------------------------- the fold

const sectionAt = (lines, heading) => {
  const at = lines.findIndex((l) => l.startsWith(`## ${heading}`))
  if (at < 0) return null
  const next = lines.findIndex((l, i) => i > at && l.startsWith('## '))
  return { at, end: next < 0 ? lines.length : next }
}
// The first line after the heading's own blank lines, where a newest-first list starts.
const bodyStart = (lines, s) => { let i = s.at + 1; while (i < s.end && !lines[i].trim()) i++; return i }
// The last non-blank line of a section, plus one.
const bodyEnd = (lines, s) => { let i = s.end; while (i > s.at + 1 && !lines[i - 1].trim()) i--; return i }

/**
 * NOW.md with these closeout notes folded in, oldest first so the newest ends
 * on top. Returns { text, folded, problems }; a note with problems, or a
 * NOW.md missing a section a note needs, is left unfolded and reported.
 */
export function foldNotes(nowText, notes) {
  const eol = /\r\n/.test(nowText) ? '\r\n' : '\n'
  let lines = String(nowText).split(/\r?\n/)
  const folded = [], problems = []
  for (const note of [...notes].sort((a, b) => a.path.localeCompare(b.path))) {
    if (note.problems.length) { problems.push(...note.problems); continue }
    const where = sectionAt(lines, 'Where it is right now')
    const waiting = sectionAt(lines, WAITING)
    const recent = sectionAt(lines, 'What changed recently')
    if (!where || !waiting || (note.changed && !recent)) { problems.push(`${NOW} is missing a section ${note.path} needs ("Where it is right now", "${WAITING}"${note.changed ? ', "What changed recently"' : ''}).`); continue }
    // Waiting on Krish: the note's North Star check replaces the old one, its next action goes on top.
    const check = `- ${note.check.text}`
    let checkAt = -1
    for (let i = waiting.at + 1; i < waiting.end; i++) if (CHECK_LINE.test(lines[i].trim())) { if (checkAt < 0) checkAt = i; else { lines.splice(i, 1); i--; waiting.end-- } }
    if (checkAt >= 0) lines[checkAt] = check
    else { const e = bodyEnd(lines, waiting); lines.splice(e, 0, check); waiting.end++ }
    // The single next action: the note's replaces every top-level "- Next" item, with its indented lines.
    for (let i = waiting.at + 1; i < waiting.end; i++) {
      if (!/^- Next\b/.test(lines[i])) continue
      let n = 1
      while (i + n < waiting.end && /^\s+\S/.test(lines[i + n])) n++
      lines.splice(i, n); i--; waiting.end -= n
    }
    lines.splice(bodyStart(lines, waiting), 0, `- Next (${note.date}): ${note.next}`)
    // What changed recently: newest first.
    if (note.changed) { const r = sectionAt(lines, 'What changed recently'); lines.splice(bodyStart(lines, r), 0, `- ${note.date} ${note.changed}`) }
    // Where it is right now: the status goes on top of its bullets, or after its prose.
    const w = sectionAt(lines, 'Where it is right now')
    let firstBullet = -1
    for (let i = w.at + 1; i < w.end; i++) if (lines[i].startsWith('- ')) { firstBullet = i; break }
    if (firstBullet >= 0) lines.splice(firstBullet, 0, `- ${note.status} (${note.date})`)
    else { const e = bodyEnd(lines, w); lines.splice(e, 0, '', `- ${note.status} (${note.date})`) }
    // as_of and the heading move forward, never back.
    const stamp = asOf(lines.join('\n'))
    if (!stamp || stamp < note.date) {
      lines = lines.map((l) => /^as_of:\s*\d{4}-\d{2}-\d{2}\s*$/.test(l) ? `as_of: ${note.date}` : l.replace(/^(## Where it is right now \(as of )\d{4}-\d{2}-\d{2}(\))/, `$1${note.date}$2`))
    }
    folded.push(note.path)
  }
  return { text: lines.join(eol), folded, problems }
}

/** Fold every note in now-notes/ into NOW.md on disk, deleting the folded notes. */
export function foldRepository(cwd) {
  const dir = join(cwd, NOTES)
  const nowPath = join(cwd, NOW)
  if (!existsSync(dir)) return { folded: [], problems: [] }
  const notes = readdirSync(dir).filter((f) => f.endsWith('.md')).map((f) => parseNote(`${NOTES}/${f}`, readFileSync(join(dir, f), 'utf8')))
  if (!notes.length) return { folded: [], problems: [] }
  if (!existsSync(nowPath)) return { folded: [], problems: [`${NOW} does not exist; ${notes.length} closeout note(s) wait in ${NOTES}/.`] }
  const result = foldNotes(readFileSync(nowPath, 'utf8'), notes)
  if (result.folded.length) {
    writeFileSync(nowPath, result.text)
    for (const p of result.folded) unlinkSync(join(cwd, p))
  }
  return result
}

// ------------------------------------------------------------------ git reads

const git = (cwd, ...a) => execFileSync('git', a, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
const tryGit = (cwd, ...a) => { try { return git(cwd, ...a) } catch { return null } }

/** Non-merge commits in base..head, oldest first, each with the files it touched. */
export function rangeCommits(cwd, base, head) {
  const SEP = '\u001e', END = '\u001f'
  const raw = tryGit(cwd, 'log', '--no-merges', '--reverse', '--name-only', `--format=${SEP}%as%n%s%n%b${END}`, `${base}..${head}`)
  if (raw == null) return null
  return raw.split(SEP).filter((s) => s.trim()).map((chunk) => {
    const [message, names = ''] = chunk.split(END)
    const [date, subject = '', ...rest] = message.split('\n')
    return { date: date.trim(), subject: subject.trim(), body: rest.join('\n').trim(), files: names.split('\n').map((s) => s.trim()).filter(Boolean) }
  })
}

/**
 * Where this session's work begins: the newest published commit HEAD sits on.
 *
 * A remote-tracking ref can be days stale (a cloud container cloned earlier
 * and checked out the latest commit without moving origin/main), and a stale
 * base pulls already-published commits, NOW.md updates included, into the
 * range, so a session that never closed out passes. So the default branch is
 * fetched first, briefly and best effort, and the local default branch is a
 * candidate too when HEAD has left it. The newest merge-base wins.
 */
export function defaultBase(cwd, { fetch = true } = {}) {
  const head = tryGit(cwd, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
  const branches = [...new Set([head?.replace(/^origin\//, ''), 'main', 'master'].filter(Boolean))]
  if (fetch) {
    for (const b of branches) {
      try {
        execFileSync('git', ['fetch', '--quiet', '--no-tags', 'origin', `+refs/heads/${b}:refs/remotes/origin/${b}`], { cwd, stdio: 'ignore', timeout: 10_000, env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } })
        break
      } catch { /* offline or no such branch: fall back to what is local */ }
    }
  }
  const current = tryGit(cwd, 'symbolic-ref', '--short', 'HEAD')
  const refs = [...branches.map((b) => `origin/${b}`), ...branches.filter((b) => b !== current)]
  let best = null
  for (const ref of refs) {
    const base = tryGit(cwd, 'merge-base', 'HEAD', ref)
    if (!base) continue
    if (!best || tryGit(cwd, 'merge-base', '--is-ancestor', best, base) === '') best = base
  }
  return best
}

const dateOf = (cwd, sha) => tryGit(cwd, 'log', '-1', '--format=%cs', sha)

function readSettings(cwd, ref) {
  if (ref) return tryGit(cwd, 'show', `${ref}:${SETTINGS}`)
  const p = join(cwd, SETTINGS)
  return existsSync(p) ? readFileSync(p, 'utf8') : null
}

/** The text of every closeout note the range touched, as it stands at ref (null when deleted). */
function readNotes(cwd, ref, commits) {
  const paths = [...new Set((commits || []).flatMap((c) => c.files).filter((p) => NOTE.test(p)))]
  return Object.fromEntries(paths.map((p) => [p, ref ? tryGit(cwd, 'show', `${ref}:${p}`) : (existsSync(join(cwd, p)) ? readFileSync(join(cwd, p), 'utf8') : null)]))
}

function readNow(cwd, ref) {
  if (ref) { const t = tryGit(cwd, 'show', `${ref}:${NOW}`); return { nowExists: t != null, nowText: t } }
  const p = join(cwd, NOW)
  return existsSync(p) ? { nowExists: true, nowText: readFileSync(p, 'utf8') } : { nowExists: false, nowText: null }
}

// ------------------------------------------------------------------ callers

export function hook(input, today = new Date().toISOString().slice(0, 10)) {
  if (input?.stop_hook_active) return null
  const cwd = input?.cwd || process.cwd()
  if (tryGit(cwd, 'rev-parse', '--is-inside-work-tree') !== 'true') return null
  const base = defaultBase(cwd)
  if (!base) return null
  const commits = rangeCommits(cwd, base, 'HEAD')
  if (!commits?.length) return null
  // Committed work is what is handed on, so it is what the hook holds to the rule.
  const result = evaluate({ commits, ...readNow(cwd, 'HEAD'), notes: readNotes(cwd, 'HEAD', commits), settingsText: readSettings(cwd, 'HEAD'), since: dateOf(cwd, base), today })
  return result.ok ? null : { decision: 'block', reason: instructions(result.problems, today) }
}

export function ci({ cwd = process.cwd(), base, head, body = '', author = '', today }) {
  const commits = rangeCommits(cwd, base, head)
  if (commits == null) return { ok: false, problems: [`Could not read commits ${base}..${head}; fetch full history (actions/checkout fetch-depth: 0).`] }
  return evaluate({ commits, body, author, ...readNow(cwd, head), notes: readNotes(cwd, head, commits), settingsText: readSettings(cwd, head), since: dateOf(cwd, base), today: today || dateOf(cwd, head) })
}

const main = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (main) {
  const args = process.argv.slice(2), flag = (f) => { const i = args.indexOf(f); return i < 0 ? null : args[i + 1] }
  if (args.includes('--fold')) {
    const result = foldRepository(process.cwd())
    for (const p of result.folded) console.log(`folded ${p}`)
    for (const p of result.problems) console.log(`::error::${p}`)
    if (!result.folded.length && !result.problems.length) console.log('No closeout notes to fold.')
    process.exit(result.problems.length ? 1 : 0)
  }
  if (args.includes('--ci')) {
    const result = ci({ base: flag('--base'), head: flag('--head') || 'HEAD', body: process.env.PR_BODY || '', author: process.env.PR_AUTHOR || '' })
    if (result.ok) { console.log(`Closeout passed: ${result.reason}.`); process.exit(0) }
    console.log(instructions(result.problems, new Date().toISOString().slice(0, 10)))
    for (const p of result.problems) console.log(`::error::${p}`)
    process.exit(1)
  }
  let raw = ''
  try { raw = readFileSync(0, 'utf8') } catch { /* no stdin */ }
  let input = {}
  try { input = raw.trim() ? JSON.parse(raw) : {} } catch { /* not a hook payload */ }
  let out = null
  try { out = hook(input) } catch { out = null } // a broken check never traps a session
  if (out) process.stdout.write(JSON.stringify(out))
  process.exit(0)
}
