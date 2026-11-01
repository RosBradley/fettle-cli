#!/usr/bin/env python3
"""Check that foreground Homebrew output does not collide with the spinner."""
import errno
import os
import pty
import select
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
script = r'''
set -euo pipefail
source "$TEST_ROOT/lib/core/common.sh"
source "$TEST_ROOT/lib/uninstall/batch.sh"
app="$HOME/Applications/Example.app"
mkdir -p "$app"
_batch_selected_app_plan_matches() { return 0; }
uninstall_live_bundle_has_other_install() { return 1; }
stop_launch_services() { :; }
unregister_app_bundle() { :; }
remove_login_item() { :; }
force_kill_app() { :; }
brew_uninstall_cask() {
    [[ -t 0 && -t 1 ]] || return 99
    printf 'BREW_FIRST\n'
    sleep .3
    printf 'BREW_SECOND\n'
    return "$TEST_RC"
}
app_details=("Example|$app|unknown|1|||false|false|true|example||||guard_login|x|unknown||missing")
success_count=0 failed_count=0 brew_apps_removed=0
failed_items=() success_items=() success_dock_targets=()
system_extension_warning_apps=() review_only_system_leftovers=()
review_only_system_leftover_keys=() running_at_uninstall_apps=()
total_size_freed=0 files_cleaned=0 total_items=0
rc=0
_batch_execute_removals || rc=$?
printf 'RESULT:%s\n' "$rc"
'''

for expected in (124, 130):
    with tempfile.TemporaryDirectory(prefix='mole-brew-output-') as home:
        master, slave = pty.openpty()
        env = dict(os.environ, HOME=home, TEST_ROOT=str(root), TEST_RC=str(expected), TERM='xterm')
        process = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', script],
                                   stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        output = b''
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], .1)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            break
                        raise
                if process.poll() is not None and not select.select([master], [], [], 0)[0]:
                    break
            process.wait(timeout=2)
            assert process.returncode == 0, output
            assert b'Removing Example (1KB)...\r\nBREW_FIRST\r\n' in output, output
            assert b'BREW_FIRST\r\nBREW_SECOND\r\n' in output, output
            assert f'RESULT:{expected}'.encode() in output, output
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
    print(f'PASS: brew output and status {expected}')
