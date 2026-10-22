"""Expand one environment entry and omit Xcode-only previews for a local CLT build."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
checkout = root / '.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts'
p = checkout / 'ConflictPolicy.swift'
p.chmod(p.stat().st_mode | 0o200)
s = p.read_text()
old = 'extension EnvironmentValues {\n\t@Entry\n\tvar keyboardShortcutsConflictPolicy = KeyboardShortcuts.ConflictPolicy.default\n}'
new = '''private struct KeyboardShortcutsConflictPolicyKey: EnvironmentKey {
    static let defaultValue = KeyboardShortcuts.ConflictPolicy.default
}

extension EnvironmentValues {
    var keyboardShortcutsConflictPolicy: KeyboardShortcuts.ConflictPolicy {
        get { self[KeyboardShortcutsConflictPolicyKey.self] }
        set { self[KeyboardShortcutsConflictPolicyKey.self] = newValue }
    }
}'''
if old in s:
    p.write_text(s.replace(old, new))
elif new not in s:
    raise SystemExit('Unexpected KeyboardShortcuts environment entry; inspect before building')
p = checkout / 'Recorder.swift'
p.chmod(p.stat().st_mode | 0o200)
s = p.read_text()
s = re.sub(r'\n#Preview \{\n.*?\n\}\n', '\n', s, flags=re.S)
assert '#Preview' not in s
p.write_text(s)
print('Applied local CLT compatibility expansion (no runtime behavior change).')
