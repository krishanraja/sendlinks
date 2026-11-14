# Recipient page mock (I-29, D20)

A rendered mock only. Nothing here is deployed or wired to `sendlinks-open`; Krish approves the
mock before anything else is built (D5, krish-design: one rendered material surface, then
explicit approval).

- `recipient-page.html`: one page, Mindmake only. `?state=ready|password|gone`,
  `?theme=light|dark` (otherwise it follows the device).
- `renders/`: phone (390 wide) and desktop (1280 wide), light and dark, at 2x.

The data in it is the real phone-check link's (an mp4 of 1.6 MB, open until 21 Nov); the
recipient address is a placeholder.

What it is for: the click on "Play the video" is the open, so a mail scanner that fetches the
page spends nothing; the password form replaces POSTing JSON; the line under the button says
plainly that opening is reported.

Still needing Krish's yes, later and separately: deploying a public page, the `/l/` path on
mindmake.co, and any environment change on a live function.
