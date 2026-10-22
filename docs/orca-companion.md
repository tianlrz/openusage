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

Orca can hardlink the same Codex rollout into several account homes. The logs do not identify the paying account, so this fork excludes files shared with another account and warns that per-account history is partial. Older Claude sessions without a proven owner are also left unassigned. No source logs are deleted or moved.

Some oversized log records may be skipped by the existing parsers. The result is an estimate over attributable, readable history, not a complete account ledger. Account-by-day filtering and five-hour historical allowance audits remain follow-up work; this fork does not establish whether a provider reduced an account's allowance.

## Build and install

Use full Xcode with Swift 6.2 or newer for the normal build and XCTest suite:

```sh
git clone --branch orca-companion https://github.com/tianlrz/openusage.git
cd openusage
swift build -c release
swift test --filter 'OrcaAccountDiscoveryTests|OrcaAccountHistoryTests|OrcaUsageReaderTests'
```

There is no signed fork download. For local packaging, first install upstream OpenUsage **0.7.15 (645)** and launch it once. The local installer reuses that app's resources and frameworks, backs up the original app and preferences, inserts the two compiled executables, and applies an ad-hoc signature:

```sh
python3 script/local-account-install.py
```

The original official update feed remains enabled. An official update can replace the patch. The app version stays unchanged; no upstream release is published. Local backups and the installation receipt are ignored by git and must remain private.

Restore the saved application while retaining current preferences:

```sh
python3 script/local-account-install.py --restore
```

The script refuses to replace a different installed version. It does not change account credentials. Keep the saved backup if you move the source checkout.

## Validation

The initial macOS ARM64 installation passed 13 standalone regression scenarios with 55 assertions, a native release build and deep code-signature verification. Four account cards were checked against Orca CLI quota results. No real emails, credentials or account IDs from that check are included in this repository. Full XCTest was unavailable on that machine because only Command Line Tools were installed; it is not reported as having passed.

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
