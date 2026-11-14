# 2026-11-14: byte ranges, so a phone can play and seek a video

- Status: live. Migration `20261114123717_sendlinks_ranges` applied (18 sendlinks functions, 11
  wrappers, none open to anon); `sendlinks-open` v6 answers `206` with `Content-Range` and
  `Accept-Ranges: bytes`. Live smoke test with a well-formed unknown token: plain, `bytes=0-` and
  `bytes=100-` all 404 cleanly (the last through the new `continue_link` wrapper). Local: 10 SQL
  suites, 23 HTTP steps; three mutations each fail them.
- Next: a live phone check (inline playback, seeking, time to first frame) once an existing
  caller mints an mp4 link; no new bearer is made for it.
- North Star check (2026-11-14): this repository has no North Star file; none was added.
