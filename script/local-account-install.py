#!/usr/bin/env python3
"""Install this local build, or restore the saved official app without changing account logins."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
APP = Path('/Applications/OpenUsage.app')
RECEIPT = ROOT / 'local-install-receipt.json'
ENV = dict(os.environ, ORCA_BACKGROUND_LAUNCH='1')


def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], check=True, env=ENV,
                          stdout=subprocess.PIPE if capture else None).stdout


def stop_app():
    rows = run('ps', '-axo', 'pid=,comm=', capture=True).decode().splitlines()
    pids = [int(row.split(None, 1)[0]) for row in rows
            if len(row.split(None, 1)) == 2 and row.split(None, 1)[1] == str(APP / 'Contents/MacOS/OpenUsage')]
    for pid in pids:
        os.kill(pid, signal.SIGTERM)
    for _ in range(100):
        alive = []
        for pid in pids:
            try:
                os.kill(pid, 0)
                alive.append(pid)
            except ProcessLookupError:
                pass
        if not alive:
            return
        time.sleep(0.1)
    raise RuntimeError('OpenUsage did not stop; app was left in place')


def main():
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument('--restore', action='store_true')
    args.add_argument('--hide-email', help='User-requested removal from local OpenUsage cards only')
    args.add_argument('--name-card', action='append', default=[], metavar='CARD_ID=NAME',
                      help='Set a local Codex card display alias without changing its login')
    options = args.parse_args()
    current = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    if current['CFBundleShortVersionString'] != '0.7.15' or str(current['CFBundleVersion']) != '645':
        raise RuntimeError('Expected OpenUsage 0.7.15 (645); inspect a different version before replacing it')
    if RECEIPT.exists():
        receipt = json.loads(RECEIPT.read_text())
    else:
        if options.restore:
            raise RuntimeError('No saved original app exists in this checkout')
        backup = ROOT / 'local-backups' / datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S-original')
        backup.mkdir(parents=True)
        run('ditto', APP, backup / 'OpenUsage.app')
        receipt = {'backup': str(backup), 'baseSHA': 'ce914d701c1e6c69dc706c5469bd96d7e6677849',
                   'installedVersion': '0.7.15', 'installedBuild': '645',
                   'originalBinarySHA256': hashlib.sha256((APP / 'Contents/MacOS/OpenUsage').read_bytes()).hexdigest()}
        RECEIPT.write_text(json.dumps(receipt, indent=2) + '\n')
    original = Path(receipt['backup']) / 'OpenUsage.app'
    if not original.is_dir():
        raise RuntimeError('Official app backup is missing; refusing to replace the app')
    stage = ROOT / 'dist/local-install/OpenUsage.app'
    stage.parent.mkdir(parents=True, exist_ok=True)
    if stage.exists():
        shutil.rmtree(stage)
    run('ditto', original, stage)
    if not options.restore:
        release = ROOT / '.build/release'
        for source, target in [('OpenUsage', 'MacOS/OpenUsage'), ('openusage-cli', 'Helpers/openusage')]:
            destination = stage / 'Contents' / target
            shutil.copy2(release / source, destination)
            run('install_name_tool', '-add_rpath', '@executable_path/../Frameworks', destination)
        for bundle in release.glob('*.bundle'):
            run('ditto', bundle, stage / 'Contents/Resources' / bundle.name)
        run('xattr', '-cr', stage)
        run('codesign', '--force', '--sign', '-', stage / 'Contents/Helpers/openusage')
        run('codesign', '--force', '--sign', '-', stage)
    run('codesign', '--verify', '--deep', '--strict', stage)
    stop_app()
    stamp = datetime.datetime.now().astimezone().strftime('%Y%m%d-%H%M%S')
    backup = ROOT / 'local-backups' / stamp
    backup.mkdir(parents=True)
    prefs = run('defaults', 'export', 'com.robinebers.openusage', '-', capture=True)
    saved = backup / 'preferences.plist'
    saved.write_bytes(prefs)
    saved.chmod(0o600)
    if options.hide_email or options.name_card:
        values = plistlib.loads(prefs)
        key = 'openusage.providerAccounts.v1'
        records = json.loads(values.get(key, b'[]'))
        hidden = 0
        for record in records:
            if options.hide_email and options.hide_email.casefold() in (record.get('label') or '').casefold():
                if record.get('family') in ['claude', 'codex']:
                    record['removedTombstone'] = True
                    hidden += 1
        for assignment in options.name_card:
            card_id, separator, name = assignment.partition('=')
            matches = [record for record in records if record['id'] == card_id
                       and record.get('family') == 'codex' and not record.get('removedTombstone')]
            if not separator or not name.strip() or len(matches) != 1:
                raise RuntimeError('Expected an existing Codex CARD_ID and a nonempty display name')
            matches[0]['displayNameOverride'] = name.strip()
        values[key] = json.dumps(records).encode()
        selected = backup / 'preferences-selected.plist'
        selected.write_bytes(plistlib.dumps(values))
        selected.chmod(0o600)
        run('defaults', 'import', 'com.robinebers.openusage', selected)
        if options.hide_email:
            print(f'Applied user-requested removal to {hidden} saved account cards; credentials unchanged.')
        if options.name_card:
            print(f'Set {len(options.name_card)} local card aliases; credentials unchanged.')
    APP.rename(backup / 'previous-live.app')
    try:
        stage.rename(APP)
    except Exception:
        (backup / 'previous-live.app').rename(APP)
        raise
    run('open', '-g', APP)
    receipt['patchedBinarySHA256'] = hashlib.sha256((APP / 'Contents/MacOS/OpenUsage').read_bytes()).hexdigest()
    receipt['lastInstalledAt'] = datetime.datetime.now().astimezone().isoformat()
    receipt['lastInstallBackup'] = str(backup)
    receipt['status'] = 'restored official app' if options.restore else 'installed; verifying refresh'
    RECEIPT.write_text(json.dumps(receipt, indent=2) + '\n')
    print(receipt['status'])


if __name__ == '__main__':
    main()
