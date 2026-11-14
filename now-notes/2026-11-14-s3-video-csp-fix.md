Status: Krish's Android still showed a broken video after the range fix. Cause: the `sandbox` CSP gave Chrome's video page origin 'null', so the player's fetch of the file was blocked as cross-origin. Video and audio now go without the sandbox (`sendlinks-open` v7); emulated Android Chrome on the live link loads, seeks and reaches ready state with no error.
Next: Krish retests the phone-check link on Android and an iPhone and the result goes into `docs/STATE.md`.
North Star check (2026-11-14): holds.
