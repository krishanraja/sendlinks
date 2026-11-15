#!/usr/bin/env python3
"""Weekly branch sweep: delete remote branches whose work is already on the default branch.

Copied byte for byte into every repository of the fleet (krishanraja/*). The canonical copy is
krishanraja/ai-harness .github/scripts/branch_sweep.py, with its workflow
.github/workflows/branch-sweep.yml; change it there first, then copy it everywhere unchanged.

Ruling (Krish, 2026-11-15): branches whose work is already on main are deleted now and weekly;
branches with unmerged work or open pull requests are kept and listed.

A branch is deleted only when all of these hold:
  - it is not the default branch, not protected, and not one of KEEP_NAMES;
  - no open pull request has it as its head or as its base;
  - either its head commit is contained in the default branch (compare default...head: ahead_by == 0),
    or its head commit is exactly the head commit of a merged pull request from that same branch
    (a squash or rebase merge).
Anything else is kept and listed with the reason. An unreadable comparison keeps the branch.

Approved mode (Ruling, Krish, 2026-11-15: the stranded branches he approved are deleted, each only
at the exact commit reviewed). When APPROVED holds `branch@sha` items (separated by spaces or
newlines), the run deletes only those branches and does no weekly sweep. A named branch is deleted
only when its current head commit equals the given sha exactly, it is not the default branch, not
protected, not one of KEEP_NAMES, and not the head or base of an open pull request. Anything else is
skipped and logged with the reason; nothing outside the list is touched.

Standard library only. Reads GITHUB_TOKEN and GITHUB_REPOSITORY; DRY_RUN=true lists without deleting;
APPROVED switches to approved mode.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

KEEP_NAMES = {'gh-pages', 'floor/rejections', 'inspo/new-drops'}
API = os.environ.get('GITHUB_API_URL', 'https://api.github.com').rstrip('/')
REPO = os.environ['GITHUB_REPOSITORY']
TOKEN = os.environ['GITHUB_TOKEN']
DRY_RUN = os.environ.get('DRY_RUN', 'true').strip().lower() in ('1', 'true', 'yes')
APPROVED = os.environ.get('APPROVED', '').split()


def call(path, method='GET'):
    req = urllib.request.Request(f'{API}/repos/{REPO}{path}', method=method, headers={
        'Accept': 'application/vnd.github+json',
        'Authorization': f'Bearer {TOKEN}',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'branch-sweep',
    })
    with urllib.request.urlopen(req, timeout=60) as r:
        body = r.read()
        return json.loads(body) if body else None


def paged(path):
    out, page = [], 1
    while True:
        sep = '&' if '?' in path else '?'
        batch = call(f'{path}{sep}per_page=100&page={page}')
        if not batch:
            return out
        out += batch
        page += 1


def q(ref):
    return urllib.parse.quote(ref, safe='/')


def report(title, groups):
    counts = ', '.join(f'{t.lower()} {len(rows)}' for t, rows in groups)
    lines = [f'{title} of {REPO} (dry run {str(DRY_RUN).lower()}): {counts}', '']
    for t, rows in groups:
        lines.append(f'{t} ({len(rows)}):')
        lines += [f'  {n}  [{why}]' for n, why in rows]
        lines.append('')
    text = '\n'.join(lines)
    print(text, flush=True)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write('```\n' + text + '\n```\n')


def approved(default, open_refs):
    verb = 'Would delete' if DRY_RUN else 'Deleted'
    deleted, skipped, failed = [], [], []
    for item in APPROVED:
        name, sep, want = item.rpartition('@')
        if not sep or not name or not want:
            skipped.append((item, 'not in the form branch@sha'))
            continue
        if name == default:
            skipped.append((name, 'default branch'))
            continue
        if name in KEEP_NAMES:
            skipped.append((name, 'in KEEP_NAMES'))
            continue
        if name in open_refs:
            skipped.append((name, 'open pull request'))
            continue
        try:
            b = call(f'/branches/{q(name)}')
        except urllib.error.HTTPError as e:
            skipped.append((name, 'branch not found' if e.code == 404 else f'read failed: HTTP {e.code}'))
            continue
        sha = b['commit']['sha']
        if b.get('protected'):
            skipped.append((name, 'protected'))
            continue
        if sha != want:
            skipped.append((name, f'head moved: approved {want}, now {sha}'))
            continue
        if DRY_RUN:
            deleted.append((name, f'at approved {sha}'))
            continue
        try:
            call(f'/git/refs/heads/{q(name)}', method='DELETE')
            deleted.append((name, f'at approved {sha}'))
        except urllib.error.HTTPError as e:
            failed.append((name, f'delete failed: HTTP {e.code}'))
    report('Approved branch delete', ((verb, deleted), ('Skipped', skipped), ('Failed', failed)))
    return 1 if failed else 0


def main():
    default = call('')['default_branch']
    pulls = paged('/pulls?state=all')
    own = lambda side: side.get('repo') and side['repo'].get('full_name') == REPO
    open_refs, merged_heads = set(), {}
    for p in pulls:
        if p['state'] == 'open':
            open_refs.add(p['base']['ref'])
            if own(p['head']):
                open_refs.add(p['head']['ref'])
        elif p.get('merged_at') and own(p['head']):
            merged_heads.setdefault(p['head']['ref'], set()).add(p['head']['sha'])
    if APPROVED:
        return approved(default, open_refs)
    branches = paged('/branches')

    deleted, kept, failed = [], [], []
    for b in sorted(branches, key=lambda b: b['name']):
        name, sha = b['name'], b['commit']['sha']
        if name == default or name in KEEP_NAMES:
            continue
        if b.get('protected'):
            kept.append((name, 'protected'))
            continue
        if name in open_refs:
            kept.append((name, 'open pull request'))
            continue
        why = None
        if sha in merged_heads.get(name, set()):
            why = 'merged pull request at this commit'
        else:
            try:
                c = call(f'/compare/{q(default)}...{sha}')
            except urllib.error.HTTPError as e:
                kept.append((name, f'compare failed: HTTP {e.code}'))
                continue
            if c.get('ahead_by') == 0:
                why = f'contained in {default}'
        if not why:
            kept.append((name, f'has work not on {default}'))
            continue
        if DRY_RUN:
            deleted.append((name, why))
            continue
        try:
            call(f'/git/refs/heads/{q(name)}', method='DELETE')
            deleted.append((name, why))
        except urllib.error.HTTPError as e:
            failed.append((name, f'delete failed: HTTP {e.code}'))

    verb = 'would delete' if DRY_RUN else 'deleted'
    lines = [f'Branch sweep of {REPO} (default {default}, dry run {str(DRY_RUN).lower()}): '
             f'{verb} {len(deleted)}, kept {len(kept)}, failed {len(failed)}', '']
    for title, rows in ((verb.capitalize(), deleted), ('Kept', kept), ('Failed', failed)):
        lines.append(f'{title} ({len(rows)}):')
        lines += [f'  {n}  [{why}]' for n, why in rows]
        lines.append('')
    text = '\n'.join(lines)
    print(text, flush=True)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as f:
            f.write('```\n' + text + '\n```\n')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
