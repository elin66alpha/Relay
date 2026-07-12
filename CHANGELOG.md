# Changelog

## Unreleased

### Added

- A Fast mode switch in the solo-chat composer for Claude Code and Codex. The
  setting defaults off and is shared by every named session in the same
  workdir/agent context.

### Changed

- Codex model and reasoning-effort choices now come from the installed CLI's
  structured catalog, including model-specific supported effort levels and
  defaults. Updating the CLI refreshes both choices without a Relay release.
- Consolidated contributor, deployment, and platform documentation around the
  current codebase; removed completed task specs, broken memory notes, duplicate
  platform pages, and roadmap-as-changelog copies.

### Fixed

- Removed false Codex model ids produced by binary string scanning and repaired
  stale or unsupported model/effort selections in solo chats and Swarms.
- CLI update failures are no longer reported as "Already up to date."
- Repaired the Linux setup entry after the one-command installer moved under
  `scripts/`.

## 0.1.3 - 2026-06-27

### Added

- First-run **Deploy backend** guide in the app, with Linux, macOS, and Windows
  setup commands and the same credential-import flow as the README.
- Background turn tracking for single-agent sessions, so long-running turns can
  continue while the user moves between sessions.
- Running-session indicators in the CLI agent drawer.
- Installed/authenticated/usable status for all five agents, selection gating,
  and in-app OAuth flows for Claude Code, Codex, and Antigravity on compatible
  backend hosts.
- More public-facing README structure, a dedicated security model, and release
  preparation documentation.

### Changed

- New-session creation no longer blocks just because another session is running.
- Credential import screens now surface scan, upload, and paste flows more
  clearly across mobile, Web, and desktop.
- Flutter and backend package metadata are bumped for the 0.1.3 release.

### Fixed

- Several chat/session state edges around switching sessions while work is still
  in progress.
- Documentation drift around production deployment and current version naming.

## 0.1.2 - 2026-06-20

- Added app screenshots and a more complete README.
- Added native agent icons and improved chat composer controls.
- Documented desktop build requirements and production deployment notes in the
  handbook.

## 0.1.0 - 2026-06-11

- First public baseline after the Relay rename.
- Hardened backend integrity, credential handling, route structure, and frontend
  state handling.
