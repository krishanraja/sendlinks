# Recipient page (I-29, D20)

The page a recipient lands on when they open a SendLinks link. Built from the approved mock
(`web/mock/`), Mindmake only for now. Static: one `index.html` plus a `config.js` written at deploy.

How it works:
- The link's token is the last path segment (`/l/{token}`).
- On load it reads the card from `sendlinks-open/{token}/meta`. That spends no view and writes a
  `previewed` event, so a mail scanner that loads the page, even one that runs its script, uses
  nothing up.
- Only the recipient's click opens the link. A video or audio file plays inline in the page (the
  `<video>` streams from `sendlinks-open` with byte ranges). A PDF or other file opens or
  downloads, a url link redirects, a text note is fetched with POST and shown.
- A password link shows the form and POSTs the password; a closed, used-up or unknown link shows
  why.

Deploy (each step needs Krish's yes; none has been done):
1. Host this folder at `https://mindmake.co/l/` with every `/l/*` path served by `index.html`,
   and write `config.js` from `config.example.js` with the project's `sendlinks-open` address
   (`$SUPABASE_URL/functions/v1/sendlinks-open`, never committed).
2. Set the `sendlinks-api` secret `SENDLINKS_PUBLIC_BASE=https://mindmake.co/l`, so new links
   point at the page. Links already sent keep working at their old address.

`renders/`: the page in Playwright as a Pixel 7, light and dark, before and after Play, run
against the live phone-check link on 2026-11-14.
