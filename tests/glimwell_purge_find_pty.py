#!/usr/bin/env python3
"""Glimwell: Purge's / Find shows what you type, in a real terminal."""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
# Fabricated rows only, as in purge_menu_pty.py.
source = (root / 'tests' / 'purge_menu_pty.py').read_text()
setup = re.search(r"setup = r'''(.*?)'''", source, re.S).group(1)
script = setup + '\nif select_purge_categories "${categories[@]}"; then echo TEST_ACCEPTED; else echo TEST_CANCELLED; fi\n'
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')

with tempfile.TemporaryDirectory(prefix='glimwell-purge-find-') as home:
    env = dict(os.environ, HOME=home, TEST_ROOT=str(root), TERM='xterm-256color',
               MOLE_TEST_NO_AUTH='1', MOLE_DRY_RUN='1', XDG_CACHE_HOME=str(Path(home) / '.cache'))
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))

    def own_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-c', script],
                               stdin=slave, stdout=slave, stderr=slave, env=env,
                               preexec_fn=own_terminal)
    os.close(slave)
    output = b''

    def receive(marker, timeout=10):
        global output
        deadline = time.monotonic() + timeout
        while marker not in ansi.sub(b'', output):
            assert time.monotonic() < deadline, ('missing', marker, ansi.sub(b'', output)[-800:])
            if select.select([master], [], [], .05)[0]:
                output += os.read(master, 65536)

    try:
        receive(b'Q Quit')
        output = b''
        os.write(master, b'/')
        receive(b'Find project/artifact: ')
        output = b''
        # Typed one key at a time, as a person types; each must show.
        for char in b'artifact-45':
            os.write(master, bytes([char]))
            time.sleep(.02)
        receive(b'artifact-45', timeout=3)
        output = b''
        os.write(master, b'\r')
        receive(b'/80]')
        assert re.findall(rb'\[(\d+)/80\]', ansi.sub(b'', output))[-1] == b'46', output[-800:]
        os.write(master, b'q')
        receive(b'TEST_CANCELLED')
        assert process.wait(timeout=3) == 0
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
        os.close(master)
print('PASS: Purge find shows the typed text and finds it')
