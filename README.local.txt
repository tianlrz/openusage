Local OpenUsage account integration

Base: OpenUsage 0.7.15 (645), ce914d701c1e6c69dc706c5469bd96d7e6677849.
This is a local arm64 build with an ad-hoc signature, not an upstream release.
The official Sparkle update feed is preserved; a future official update can replace this patch.

Behavior:
- Reuses OpenUsage's existing per-account cards and usage clients.
- Reads the active Orca profile registry; migrated SQLite state overrides stale JSON/directories.
- Supports legacy managed Claude auth and newer Claude profile homes, plus managed Codex homes.
- Live limits use read-only orca account list --json, matched by account/workspace IDs.
- One CLI read per minute at most, on the existing five-minute app refresh cycle; no new background daemon.
- Orca timestamps are preserved and old results marked; no direct login is needed for these cards.
- Deleted OpenUsage accounts remain removed. Restart OpenUsage after source account changes.
- Shared Codex hardlinks are read once; new usage follows continuously observed local session writers.
- Observation gaps remain visible in a separate unassigned-usage section. A chosen historical
  baseline can be assigned manually with --codex-history-owner CARD_ID.
- Legacy unowned Claude sessions remain unassigned.
- Historical cost is a token-price estimate, not subscription fees or a proven quota allowance.

Validation:
Full XCTest needs Xcode, which this machine does not have. A standalone runner imports the actual
production module and runs the added account/history tests without XCTest or real credentials:
  OPENUSAGE_ACCOUNT_VALIDATION=1 swift build -c release --product AccountValidation
  ORCA_BACKGROUND_LAUNCH=1 .build/release/AccountValidation
Read-only real account metadata probe, no network or credential writes:
  ORCA_BACKGROUND_LAUNCH=1 .build/release/AccountValidation --local-discovery

Rebuild with the installed CLT SDK:
  python3 script/clt-swiftui-compat.py
  OPENUSAGE_ACCOUNT_VALIDATION=1 ORCA_BACKGROUND_LAUNCH=1 swift build -c release --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
Then install without changing focus:
  python3 script/local-account-install.py
Restore the saved official application, retaining current OpenUsage preferences:
  python3 script/local-account-install.py --restore

The original app, pre-install preferences and install receipt are local-only and ignored by git.
No account credentials are copied into this checkout. See docs/orca-companion.md for the public fork setup and related Orca work.
