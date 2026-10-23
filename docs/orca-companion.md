# OpenUsage with Orca

This personal fork adds a macOS quota dashboard for accounts managed by Orca. Its base is upstream OpenUsage v0.7.15 (645), commit `ce914d701c1e6c69dc706c5469bd96d7e6677849`. The fork is not an official release from either project.

## What works

- Separate Claude and Codex account cards, including inactive accounts.
- Five-hour and weekly quota percentages and reset times supplied by `orca account list --json`.
- The existing Today, Yesterday and Last 30 Days token and estimated-cost rows, plus the daily history chart, where logs can be attributed to an account.
- Exact Orca account-ID matching, with a workspace check for Codex. A missing account reading never borrows another account's quota.

The app follows its existing five-minute refresh cycle. The cards share a CLI result for up to one minute. Quota timestamps show when Orca checked the provider, and older results display a warning. Reading the CLI does not force Orca to refresh its provider cache.

Orca remains responsible for login, token renewal, account selection and resets. These account cards do not make separate provider OAuth requests for quota. Orca must be running, its CLI must be installed, and its `account list --json` response must include Claude/Codex accounts and rate limits. Older CLI versions without these fields are unsupported. Set `ORCA_CLI_COMMAND` to an absolute executable path if Orca is installed somewhere other than `/usr/local/bin/orca`; the variable must be available to the process launching OpenUsage.

Account discovery reads the active local Orca profile. Its SQLite state takes precedence over old JSON and leftover account directories. Both legacy Claude managed-auth directories and newer Claude profile homes are supported. Restart OpenUsage after account changes. Removing an OpenUsage card does not delete the account from Orca.

## History limitations

Quota percentages and historical token/cost estimates are different data sources. The estimates are not subscription bills and do not reveal a provider's hidden quota formula.

Orca can hardlink the same Codex rollout into several account homes. The fork now reads these logs once rather than dropping the entire shared file, and deduplicates events before splitting account totals.

New Codex usage follows local session writers: the native process's `CODEX_HOME`, process start time and writable rollout handles establish a session/account binding. A lightweight observer checks every 15 seconds and saves continuously observed ownership intervals. Switching the account selected for future launches does not move an existing session's consumption. One file lock prevents the app and one-shot CLI from overwriting each other's observations.

Events outside verified intervals, from conflicting writers, after observation failures or from unobserved hosts remain in **Codex — Unassigned Usage**. This extra history section uses the existing spend/trend rows and their existing layout defaults; it is not another login and its unresolved history is not exported to iCloud. Such consumption remains visible without being charged to the wrong account. Closed short-lived sessions, app downtime and remote sessions can still leave attribution gaps; this is not a server-side billing audit.

For a user-directed historical baseline, install with `--codex-history-owner CARD_ID`. All existing log events through installation time are then assigned to that Orca account, with a visible manual-allocation notice. Future events continue to use observed writers. This is an explicit bookkeeping choice, not recovered proof of the historical payer. No source logs are changed. Older Claude sessions without a proven owner remain unassigned.

Some oversized log records may be skipped by the existing parsers. The result is an estimate over readable logs with observed or explicitly chosen ownership, not a complete provider billing ledger. Account-by-day filtering remains follow-up work. Five-hour audit collection starts when this build runs; it does not establish whether a provider reduced an account's allowance.

## Five-hour window audit

Hover or click **5h History** beside an account's existing Session label. Choose from its latest 24 observed windows. No extra login card or metric is added. Claude and Codex use the same collector with independent Orca account IDs; selecting another account does not move earlier samples.

Each window retains the provider's original percentage and timestamp, the time this Mac received it, a captured local token/cost subtotal through that source time, and the accompanying weekly reading when available. Captured subtotals remain in the original evidence even if logs or model prices later change; the detail also recomputes current log subtotals. Subsecond reset-time noise is grouped into the same second while each raw reading retains its original precision. Re-reading the same Orca cache does not create another sample. Windows follow the provider's actual five-hour reset time, rather than local clock blocks. An early reset shortens the previous window so overlapping logs are not counted twice. The app retains 30 days of collected readings, including across restarts. There is no reconstruction of pre-installation percentages.

The detail separates local usage within the window from usage **between the first and last provider readings**. Both show input, output, cache-read and cache-write tokens and an API-price estimate. Models are listed separately. Unknown prices do not hide tokens: the displayed dollar subtotal is marked partial. A cost-per-10-percentage-points figure is available only with at least two readings, a change of at least 10 points, known prices and no observed sampling problems. This is an observed local comparison, not a measured subscription allowance or evidence of account penalties.

Claude audit events require recorded session account/organization ownership or an account-specific Desktop session index. They never inherit ownership merely from the currently selected login. Codex reuses the existing continuously observed session-writer ledger and the user-directed historical allocation. Unassigned Codex events remain outside account audits. Background sessions present in the attributed native logs are included; usage on the web, in other tools, on remote hosts or other devices may be missing. Effort settings are not inferred from these token records. Model, cache and service-tier differences still matter when comparing windows.

Late starts, stale readings, gaps over 10 minutes, percentage decreases and missing prices are called out. Missing or non-five-hour reset information leaves the audit waiting rather than inventing a window. This collector follows the existing five-minute refresh, makes no additional provider requests and does not force-refresh Orca's account cache.

Raw local readings are saved privately at `~/Library/Application Support/OpenUsage/quota-window-audit.json` (mode 600). A file lock serializes app/CLI saves. Unreadable evidence is preserved and reported rather than replaced. The audit stays local and is not part of iCloud history export. The existing loopback API exposes reports and their underlying samples at `/v1/audit`, `/v1/audit/claude`, `/v1/audit/codex` or `/v1/audit/CARD_ID`, using ISO-8601 dates. The API includes all retained windows, while the popover shows the newest 24.

## Build and install

Use full Xcode with Swift 6.2 or newer for the normal build and XCTest suite:

```sh
git clone --branch orca-companion https://github.com/tianlrz/openusage.git
cd openusage
swift build -c release
swift test --filter 'OrcaAccountDiscoveryTests|OrcaAccountHistoryTests|OrcaUsageReaderTests|OrcaCodexOwnershipTests|QuotaAuditTests'
```

There is no signed fork download. For local packaging, first install upstream OpenUsage **0.7.15 (645)** and launch it once. The local installer reuses that app's resources and frameworks, backs up the original app and preferences, inserts the two compiled executables, and applies an ad-hoc signature:

```sh
python3 script/local-account-install.py
```

To set a local display alias while installing, pass `--name-card 'CARD_ID=NAME'` (repeat for several Codex cards). Use the stable card ID shown by `/v1/usage`; for example, `--name-card 'codex=Work'`. The alias survives account discovery without changing credentials, discovered email or usage ownership. Personal aliases are stored only in local preferences.

The original official update feed remains enabled. An official update can replace the patch. The app version stays unchanged; no upstream release is published. Local backups and the installation receipt are ignored by git and must remain private.

Restore the saved application while retaining current preferences:

```sh
python3 script/local-account-install.py --restore
```

The script refuses to replace a different installed version. It does not change account credentials. Keep the saved backup if you move the source checkout.

## Validation

The local macOS ARM64 standalone runner passes 32 account-isolation and quota-audit scenarios with 160 assertions. Release builds and deep code-signature verification are also checked. The audit's populated and waiting states were rendered in hidden native hosting views; no test window was shown. Four account cards were checked against Orca CLI quota results. No real emails, credentials or account IDs from that check are included in this repository. Full XCTest requires Xcode and runs in the fork's macOS GitHub CI; the standalone runner is used locally because only Command Line Tools are installed.

A standalone runner imports the production module for machines without XCTest. Enable it explicitly when building; ordinary production builds do not enable test-only access:

```sh
OPENUSAGE_ACCOUNT_VALIDATION=1 swift build -c release --product AccountValidation
ORCA_BACKGROUND_LAUNCH=1 .build/release/AccountValidation
```

A metadata-only probe uses temporary OpenUsage preferences and does not make provider API requests or write credentials:

```sh
ORCA_BACKGROUND_LAUNCH=1 .build/release/AccountValidation --local-discovery
```

For the initial machine's CLT-only setup, the installed macOS 26.5 SDK was used. After `swift package resolve`, `python3 script/clt-swiftui-compat.py` expands one dependency environment entry and removes Xcode-only previews in the ignored dependency checkout. Then build with `--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. This is a local workaround, not a portable replacement for Xcode.

## Related Orca work

[Orca PR #29680](https://github.com/stablyai/orca/pull/29680) adds Today / Last 7 days / Last 30 days / All time filters to Orca's combined Usage Overview. It addresses the same need to inspect consumption over a chosen period. Viewing quotas across accounts is a related follow-up, not a feature already implemented by that PR.
