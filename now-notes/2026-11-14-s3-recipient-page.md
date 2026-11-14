Status: The recipient page is built from the approved mock (`web/recipient/`, PR #16) and its card endpoint is live (`sendlinks-open` v8, migration `20261114191454_sendlinks_link_card`); in an emulated Pixel 7 against the live link the card loads and the video plays inside the page. It is not hosted yet.
Next: with Krish's yes, host `web/recipient/` at `mindmake.co/l/` and set `SENDLINKS_PUBLIC_BASE=https://mindmake.co/l` on `sendlinks-api`.
North Star check (2026-11-14): holds.
