# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Use GitHub's private
vulnerability reporting: open the **Security** tab of
[martino-vigiani/dictari](https://github.com/martino-vigiani/dictari/security) and choose
**Report a vulnerability**.

Include what you found, how to reproduce it, the Dictari and macOS versions, and what an attacker
could do with it. You will get a reply as soon as I can read it. Dictari is maintained by one
person, so please allow a few days.

## What is in scope

Dictari is a local app, but it touches sensitive parts of macOS. Reports about these are the most
useful:

- **Event tap and Accessibility.** The global shortcut uses a `CGEventTap`, and text delivery
  posts synthetic key events and paste commands into other apps.
- **Local MCP server.** An optional server on `127.0.0.1` that lets AI agents read transcripts,
  statistics, media and vocabulary. It is off by default and every request needs a bearer token.
  Token handling, host and origin checks, and the access switches are all in scope.
- **Sparkle updates.** Update feed, signature checks and the install path.
- **Model downloads.** Integrity of downloaded model files.
- **Local data.** History, recordings and vocabulary under
  `~/Library/Application Support/Dictari/`.

Problems in third-party dependencies should go to their maintainers, but tell me if Dictari uses
them in a way that makes the problem worse.

## Supported versions

Only the latest release gets security fixes.
