#!/usr/bin/env bats

load helpers/common

# The paginated/simple selectors override EXIT/INT/TERM while they run.
# They must restore the caller's traps on exit, or an outer handler (e.g.
# bin/uninstall.sh's session-end operation-log writer) is silently dropped.

setup_file() {
    mole_test_setup_project_root
}

@test "paginated_multi_select preserves the caller's EXIT trap" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

# Neutralize terminal control so the menu runs headless.
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
clear() { :; }
printf_at() { :; }
export MOLE_MANAGED_ALT_SCREEN=1
export MOLE_READ_KEY_FORCE_CHAR=1

# Arm an outer EXIT trap exactly like bin/uninstall.sh does.
trap 'echo OUTER_EXIT_MARKER' EXIT

# A single ENTER confirms the current (empty) selection.
# Feed input via redirection, NOT a pipe: a pipe would run the menu in a
# subshell and hide its trap manipulation from this shell.
paginated_multi_select "Pick" "alpha" "beta" < <(printf '\n') > /dev/null 2>&1 || true

# The caller's EXIT trap must still be armed after the menu returns.
current_exit_trap=$(trap -p EXIT)
[[ "$current_exit_trap" == *OUTER_EXIT_MARKER* ]] || { echo "OUTER EXIT TRAP LOST: $current_exit_trap"; exit 1; }
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # The outer trap should also actually fire when the shell exits.
    [[ "$output" == *OUTER_EXIT_MARKER* ]] || return 1
}

@test "paginated_multi_select restores a caller that had no EXIT trap" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
export MOLE_MANAGED_ALT_SCREEN=1
export MOLE_READ_KEY_FORCE_CHAR=1

# Feed input via redirection, NOT a pipe: a pipe would run the menu in a
# subshell and hide its trap manipulation from this shell.
paginated_multi_select "Pick" "alpha" "beta" < <(printf '\n') > /dev/null 2>&1 || true

# No caller EXIT trap existed; the menu's own cleanup trap must be gone,
# not left dangling.
current_exit_trap=$(trap -p EXIT)
[[ -z "$current_exit_trap" ]] || { echo "STRAY EXIT TRAP: $current_exit_trap"; exit 1; }
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "paginated_multi_select does not replace the caller cleanup function" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
export MOLE_MANAGED_ALT_SCREEN=1

cleanup() { echo OUTER_CLEANUP_MARKER; }
trap cleanup EXIT
original_cleanup=$(declare -f cleanup)

paginated_multi_select "Pick" "alpha" "beta" < <(printf 'q') > /dev/null 2>&1 || true

current_cleanup=$(declare -f cleanup)
[[ "$current_cleanup" == "$original_cleanup" ]] || {
    printf 'caller cleanup function was replaced:\n%s\n' "$current_cleanup" >&2
    exit 1
}
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *OUTER_CLEANUP_MARKER* ]] || return 1
}

@test "simple paginated_multi_select keeps the caller's cleanup and interrupt handlers" {
    # lib/ui/menu_simple.sh backs `mo clean --whitelist`, where bin/clean.sh
    # has already armed `trap 'cleanup EXIT $?' EXIT` with its own cleanup().
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_simple.sh"

enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { :; }
export MOLE_MANAGED_ALT_SCREEN=1

cleanup() { echo "OUTER_CLEANUP_MARKER $1"; }
handle_interrupt() { echo OUTER_INTERRUPT_MARKER; }
trap 'cleanup EXIT' EXIT
trap handle_interrupt INT TERM
original_cleanup=$(declare -f cleanup)
original_interrupt=$(declare -f handle_interrupt)

paginated_multi_select "Pick" "alpha" "beta" < <(printf 'q') > /dev/null 2>&1 || true

current_cleanup=$(declare -f cleanup)
[[ "$current_cleanup" == "$original_cleanup" ]] || {
    printf 'caller cleanup function was replaced:\n%s\n' "$current_cleanup" >&2
    exit 1
}
current_interrupt=$(declare -f handle_interrupt)
[[ "$current_interrupt" == "$original_interrupt" ]] || {
    printf 'caller handle_interrupt function was replaced:\n%s\n' "$current_interrupt" >&2
    exit 1
}
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"OUTER_CLEANUP_MARKER EXIT"* ]] || return 1
}

@test "footer never drops the Space Select hint before secondary controls (#1382)" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail

# The footer is the only place that teaches multi-select. Dropping it on a
# narrow terminal made `mo uninstall` read as single-select (#1382), so every
# control-footer variant except the filter-mode one must keep it.
awk '
    /^[[:space:]]*#/ { next }
    /_segs=\(|_segs_simple=\(/ {
        seen++
        if ($0 !~ /\$space_select/) { bad++; print "missing space_select: " $0 }
    }
    END { exit (!seen || bad) }
' "$PROJECT_ROOT/lib/ui/menu_paginated.sh" || exit 1
echo ok
EOF

	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[[ "$output" == *"ok"* ]]
}

@test "paginated_multi_select search keeps pasted and fast-typed terms" {
    command -v python3 > /dev/null 2>&1 || skip "python3 not available"
    run python3 "$PROJECT_ROOT/tests/menu_search_pty.py"
    [ "$status" -eq 0 ]
}

@test "menu controls hide secondary hints before wrapping and reserve their actual rows" {
    run env PROJECT_ROOT="$PROJECT_ROOT" python3 <<'PY'
import os
import re
import subprocess

script = r'''
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
tput() { if [[ "$1" == cols ]]; then echo "$COLUMNS"; else echo "$LINES"; fi; }
read_key() { echo QUIT; }
items=()
for ((i=0; i<40; i++)); do items+=("App $i"); done
MOLE_MENU_META_SIZEKB=1
paginated_multi_select Pick "${items[@]}" || true
'''
ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
cases = 0
for columns in (35, 36, 37, 39, 40, 46, 47, 48, 53, 54, 55, 56, 57, 59, 60, 67, 68, 69, 79, 80, 81, 82, 83, 84, 120):
    for mode, select_all in (('size', 'false'), ('name', 'false'), ('size', 'true')):
        env = dict(os.environ, COLUMNS=str(columns), LINES='12', LC_ALL='C',
                   MOLE_MENU_SORT_MODE=mode, _MOLE_MENU_SELECT_ALL=select_all)
        result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script],
                                env=env, capture_output=True, text=True, check=True)
        lines = ansi.sub('', result.stderr).splitlines()
        controls = [line for line in lines if re.match(
            r'(?:↑↓|Space Select|A All|Enter Save|Q Cancel|S |O |/ Search|h/l Page)', line)]
        footer = ' | '.join(controls)
        for key in ('Space Select', 'Enter Save', 'Q Cancel'):
            assert key in footer, (columns, mode, key, controls)
        for index, line in enumerate(controls):
            assert len(line) <= columns, (columns, line)
            if index + 1 < len(controls):
                next_segment = controls[index + 1].split(' | ')[0]
                assert len(line) + 3 + len(next_segment) > columns, (columns, controls)
        if columns >= 36:
            assert len(controls) == 1, (columns, mode, controls)
        if columns >= 47:
            assert '/ Search' in footer, (columns, controls)
        if columns == 54:
            assert 'S ' not in footer and 'O ' not in footer and 'h/l Page' not in footer, controls
        if columns == 120:
            for key in ('↑↓', 'S ', 'O ', '/ Search', 'h/l Page'):
                assert key in footer, (key, controls)
            assert ('A All' in footer) == (select_all == 'true'), controls
        item_rows = [line for line in lines if 'App ' in line]
        assert len(item_rows) == 12 - 4 - len(controls), (columns, mode, len(item_rows), controls)
        cases += 1
for columns in (23, 24, 34, 35, 36, 39, 40, 49, 50, 51, 54, 80):
    env = dict(os.environ, COLUMNS=str(columns), LINES='12', LC_ALL='C',
               MOLE_READ_KEY_FORCE_CHAR='1')
    result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script],
                            env=env, capture_output=True, text=True, check=True)
    frame = next(frame for frame in result.stderr.split('\x1b[H') if 'Enter Apply' in frame)
    lines = ansi.sub('', frame).splitlines()
    controls = [line for line in lines if line.startswith('Enter Apply')]
    assert len(controls) == 1 and len(controls[0]) <= columns, (columns, controls)
    assert 'Esc Clear' in controls[0], (columns, controls)
    if columns >= 50:
        assert 'Backspace' in controls[0] and 'Ctrl+U Clear' in controls[0], controls
    cases += 1
print(f'PASS: {cases} browse/search footer layouts under LC_ALL=C')
PY
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "menu rows are cut to the terminal width so none wraps, and a details screen opens on Enter" {
    run env PROJECT_ROOT="$PROJECT_ROOT" python3 <<'PY'
import os
import re
import subprocess

script = r'''
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
drain_pending_input() { :; }
tput() { if [[ "$1" == cols ]]; then echo "$COLUMNS"; else echo "$LINES"; fi; }
KEYS=(ENTER SPACE QUIT CHAR:d)
read_key() {
    local n
    n=$(cat "$KEY_STATE" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$KEY_STATE"
    echo "${KEYS[n]:-QUIT}"
}
show_row() { printf 'Details of row %s\n' "$1"; }
items=("$(printf 'a%.0s' {1..200})" "short row" "$(printf '中%.0s' {1..80})")
MOLE_MENU_DETAILS_FN=show_row
_MOLE_MENU_KEEP_EMPTY=true
paginated_multi_select Pick "${items[@]}" || echo "rc=$?"
echo "result=$MOLE_SELECTION_RESULT"
'''
ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
env = dict(os.environ, COLUMNS='60', LINES='12', KEY_STATE=os.path.join(os.environ['BATS_TEST_TMPDIR'], 'keys'))
result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script],
                        env=env, capture_output=True, text=True, check=True)
screen = ansi.sub('', result.stderr).replace('\r', '\n')
rows = [line for line in screen.splitlines() if 'aaa' in line or '中' in line]
assert rows, screen
for line in rows:
    # Four columns of arrow, checkbox and spaces, then at most 55.
    width = sum(2 if ord(ch) > 0x2fff else 1 for ch in line[4:])
    assert width <= 55 and line.endswith('...'), (width, line)
assert 'Enter Details' in screen and 'D Save' in screen, screen
assert 'Details of row 0' in screen and 'Space Select' in screen and 'Enter Back' in screen, screen
assert 'result=0' in result.stdout, result.stdout
print('ok')
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"ok"* ]]
}

@test "a column heading sits under the search line and the list starts a row lower" {
    run env PROJECT_ROOT="$PROJECT_ROOT" python3 <<'PY'
import os
import re
import subprocess

script = r'''
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
drain_pending_input() { :; }
tput() { if [[ "$1" == cols ]]; then echo "$COLUMNS"; else echo "$LINES"; fi; }
KEYS=(DOWN SPACE QUIT)
read_key() {
    local n
    n=$(cat "$KEY_STATE" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$KEY_STATE"
    echo "${KEYS[n]:-QUIT}"
}
MOLE_MENU_COLUMNS_HEADER="Name   Size"
paginated_multi_select Pick "first" "second" "third" || echo "rc=$?"
'''
env = dict(os.environ, COLUMNS='60', LINES='12', KEY_STATE=os.path.join(os.environ['BATS_TEST_TMPDIR'], 'keys'))
result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script],
                        env=env, capture_output=True, text=True, check=True)
out = result.stderr
plain = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', out).replace('\r', '')
lines = [l for l in plain.split('\n') if l.strip()]
# Title, search line, heading, then the rows.
assert lines[1].startswith('Search') and lines[2] == '    Name   Size' and 'first' in lines[3], lines[:5]
# DOWN redraws rows 4 and 5 (the first and second item), not 3 and 4.
assert '\x1b[4;1H' in out and '\x1b[5;1H' in out, out
print('ok')
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"ok"* ]]
}

@test "S reaches the headings, where Enter opens a column's menu to sort by it either way" {
    run env PROJECT_ROOT="$PROJECT_ROOT" python3 <<'PY'
import os
import re
import subprocess

script = r"""
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
drain_pending_input() { :; }
tput() { if [[ "$1" == cols ]]; then echo "$COLUMNS"; else echo "$LINES"; fi; }
read -r -a KEYS <<< "$KEY_LIST"
read_key() {
    local n
    n=$(cat "$KEY_STATE" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$KEY_STATE"
    echo "${KEYS[n]:-QUIT}"
}
MOLE_MENU_COLUMNS_HEADER="Name    Size"
MOLE_MENU_SORT_COLUMNS=("Name|text" "Size|num:desc")
MOLE_MENU_SORT_KEYS=($'beta\x1falpha\x1fgamma' $'300\x1f100\x1f200')
MOLE_MENU_SORT_MODE=col:0
paginated_multi_select Pick "beta    300" "alpha   100" "gamma   200" || echo "rc=$?"
echo "result=$MOLE_SELECTION_RESULT"
"""
ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def run(keys, tag):
    state = os.path.join(os.environ['BATS_TEST_TMPDIR'], 'keys-' + tag)
    env = dict(os.environ, COLUMNS='60', LINES='14', KEY_STATE=state, KEY_LIST=keys)
    r = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script],
                       env=env, capture_output=True, text=True, check=True)
    return r.stdout, r.stderr


# Enter on the list picks the row under the cursor: the first row, A-Z.
out, err = run('ENTER', 'plain')
assert 'result=1' in out, out
assert 'Name▲' in ansi.sub('', err), err
# Until S is used, the heading line says how to sort.
assert 'S: sort by a column' in ansi.sub('', err), err

# S, Right to Size, Enter opens its menu; its first sort is largest first,
# as its spec says. Enter on the list then picks the first row.
out, err = run('CHAR:s RIGHT ENTER ENTER ENTER', 'size')
assert 'result=0' in out, out
screen = ansi.sub('', err)
assert 'Size▼' in screen and 'Enter Sort or filter' in screen and 'Sort: highest first' in screen and 'Then sort: highest first' in screen, screen
assert '\x1b[7mSize' in err, err

# Its second sort is smallest first.
out, err = run('CHAR:s RIGHT ENTER DOWN ENTER ENTER', 'reverse')
assert 'result=1' in out, out
assert 'Size▲' in ansi.sub('', err), err

# Left stops at the first column; its menu's second sort is Z to A, and
# Down puts the cursor on the second row, beta.
out, err = run('CHAR:s LEFT LEFT ENTER DOWN ENTER DOWN SPACE ENTER', 'name')
assert 'result=0' in out, out

# Space does nothing on the headings; Down goes back and Space selects.
out, err = run('CHAR:s SPACE DOWN SPACE ENTER', 'space')
assert 'result=1' in out, out
print('ok')
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"ok"* ]]
}

@test "lists wrap at both ends, single-pick lists return a row, filter headings narrow the list and a list reopens as it was left" {
    run env PROJECT_ROOT="$PROJECT_ROOT" python3 <<'PY'
import os
import re
import subprocess

script = r"""
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
drain_pending_input() { :; }
tput() { if [[ "$1" == cols ]]; then echo "$COLUMNS"; else echo "$LINES"; fi; }
read -r -a KEYS <<< "$KEY_LIST"
read_key() {
    local n
    n=$(cat "$KEY_STATE" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$KEY_STATE"
    echo "${KEYS[n]:-QUIT}"
}
MOLE_MENU_COLUMNS_HEADER="Name    MLX"
MOLE_MENU_SORT_COLUMNS=("Name|text" "MLX|filter")
MOLE_MENU_SORT_KEYS=($'beta\x1falpha\x1fgamma\x1fdelta' $'1\x1f0\x1f1\x1f0')
MOLE_MENU_SORT_MODE=col:0
MOLE_MENU_SINGLE="$SINGLE"
MOLE_MENU_SIDE_RETURN="$SIDE"
MOLE_MENU_INTRO="$INTRO"
MOLE_MENU_SEARCH="$SEARCH"
MOLE_MENU_START_ITEM="$START"
rc=0
paginated_multi_select Pick "beta    MLX" "alpha" "gamma   MLX" "delta" || rc=$?
echo "rc=$rc result=$MOLE_SELECTION_RESULT action=$MOLE_MENU_ACTION start=$MOLE_MENU_START_ITEM search=$MOLE_MENU_SEARCH filters=$MOLE_MENU_COLUMN_FILTERS order=$MOLE_MENU_VIEW_ORDER headings=$MOLE_MENU_HEADINGS_USED"
"""
ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def run(keys, tag, **extra):
    state = os.path.join(os.environ['BATS_TEST_TMPDIR'], 'keys-' + tag)
    env = dict(os.environ, COLUMNS='60', LINES='16', KEY_STATE=state, KEY_LIST=keys,
               SINGLE='', SIDE='', INTRO='', SEARCH='', START='')
    env.update(extra)
    r = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script],
                       env=env, capture_output=True, text=True, check=True)
    return r.stdout, ansi.sub('', r.stderr)


# A-Z: alpha(1), beta(0), delta(3), gamma(2). Up on the first row goes to
# the last, and Down there back to the first.
out, _ = run('UP ENTER', 'wrap-up')
assert 'result=2' in out, out
out, _ = run('UP DOWN ENTER', 'wrap-down')
assert 'result=1' in out, out

# A single-pick list has no checkboxes; Enter returns the row under the
# cursor, and Space selects nothing.
out, err = run('DOWN SPACE ENTER', 'single', SINGLE='true')
assert 'rc=0 result=0 action=open' in out, out
assert '○' not in err and '4 of 4' in err and 'Enter Open' in err, err

# The filter heading's menu: Show all, MLX, not MLX. Enter on MLX shows
# only its rows, and the title says so.
out, err = run('CHAR:s RIGHT ENTER DOWN ENTER ENTER', 'filter', SINGLE='true')
assert 'result=0' in out and 'filters=MLX=1' in out and 'order=0,2' in out and 'headings=true' in out, out
assert 'Filtered: MLX · 2 of 4' in err and 'MLX●' in err and 'not MLX  (2)' in err, err

# Left and Right return to the caller, with the list's state.
out, err = run('DOWN DOWN RIGHT', 'side', SIDE='true')
assert 'rc=0 result= action=next start=3' in out, out
assert '← → Other row' in err, err

# Intro lines sit above the search line; a reopened list keeps its search
# and puts the cursor on the row it was on.
out, err = run('ENTER', 'reopen', SINGLE='true', INTRO='About these rows', SEARCH='a', START='3', MOLE_MENU_HEADINGS_USED='true')
assert 'result=3' in out and 'search=a' in out and 'headings=true' in out, out
assert 'S: sort by a column' not in err, err
lines = [l for l in err.replace('\r', '\n').split('\n') if l.strip()]
assert lines[1] == 'About these rows' and lines[2].startswith('/ Search: a'), lines[:4]
print('ok')
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"ok"* ]]
}

@test "heading menus sort by a second column, tick choices with their counts, filter hidden fields from F, and X clears" {
    run env PROJECT_ROOT="$PROJECT_ROOT" python3 <<'PY'
import os
import re
import subprocess

script = r"""
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"
enter_alt_screen() { :; }
leave_alt_screen() { :; }
stty() { :; }
drain_pending_input() { :; }
tput() { if [[ "$1" == cols ]]; then echo "$COLUMNS"; else echo "$LINES"; fi; }
read -r -a KEYS <<< "$KEY_LIST"
read_key() {
    local n
    n=$(cat "$KEY_STATE" 2> /dev/null || echo 0)
    echo $((n + 1)) > "$KEY_STATE"
    echo "${KEYS[n]:-QUIT}"
}
MOLE_MENU_COLUMNS_HEADER="Name    Pulls   Month"
MOLE_MENU_SORT_COLUMNS=("Name|text" "Pulls|num" "Month|none" "Maker|none|hidden")
MOLE_MENU_SORT_KEYS=($'alpha\x1fbeta\x1fgamma\x1fdelta\x1feps\x1fzeta' $'10\x1f20\x1f20\x1f30\x1f10\x1f30')
MOLE_MENU_COL_VALUES=("" "" $'m2026-11\x1fm2026-10\x1fm2025-03\x1fm2026-11\x1fm2025-03\x1fm2026-10' $'mk_a\x1fmk_b\x1fmk_a\x1fmk_b\x1fmk_a\x1fmk_a')
MOLE_MENU_COL_CHOICES=("" "" $'+\t2026\tm2026-11 m2026-10\nm2026-11\tNovember 2026\nm2026-10\tOctober 2026\n+\t2025\tm2025-03\nm2025-03\tMarch 2025' $'mk_a\tAcme\nmk_b\tBolt')
MOLE_MENU_SORT_MODE=col:0
MOLE_MENU_SINGLE=true
paginated_multi_select Pick "alpha   10      Nov" "beta    20      Oct" "gamma   20      Mar" "delta   30      Nov" "eps     10      Mar" "zeta    30      Oct" || echo "rc=$?"
echo "result=$MOLE_SELECTION_RESULT order=$MOLE_MENU_VIEW_ORDER filters=$MOLE_MENU_COLUMN_FILTERS sort2=$MOLE_MENU_SORT2_MODE"
"""
ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def run(keys, tag):
    state = os.path.join(os.environ['BATS_TEST_TMPDIR'], 'keys-' + tag)
    env = dict(os.environ, COLUMNS='120', LINES='24', KEY_STATE=state, KEY_LIST=keys)
    r = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-c', script],
                       env=env, capture_output=True, text=True, check=True)
    return r.stdout, ansi.sub('', r.stderr)


# Pulls highest first, then Name A to Z second: 30 (delta, zeta), 20 (beta,
# gamma), 10 (alpha, eps).
out, err = run('CHAR:s RIGHT ENTER DOWN ENTER CHAR:s LEFT ENTER DOWN DOWN ENTER ENTER', 'then')
assert 'result=3' in out and 'order=3,5,1,2,0,4' in out and 'sort2=col:0' in out, out
assert 'Then sort: A to Z' in err and 'Pulls▼' in err and 'Name▲²' in err, err

# F lists every field, the hidden Maker too: Acme (4 rows) only. Then the
# Month heading's menu counts the rows Acme leaves, by year and month;
# Space on 2026 ticks both its months, and Enter shows them.
keys = 'CHAR:f DOWN DOWN DOWN ENTER DOWN ENTER CHAR:s RIGHT RIGHT ENTER DOWN SPACE ENTER'
out, err = run(keys + ' ENTER', 'filters')
assert 'result=0' in out and 'order=0,5' in out, out
assert 'filters=Month=m2026-11 m2026-10;Maker=mk_a' in out, out
assert 'Filter or sort by' in err and 'Maker' in err and 'Acme  (4)' in err and 'Bolt  (2)' in err, err
assert '2026  (2)' in err and 'November 2026  (1)' in err and 'March 2025  (2)' in err, err
assert 'Filtered: Month: November 2026, October 2026 · Maker: Acme · 2 of 6' in err, err
assert 'X Clear filters' in err, err

# X clears every filter.
out, err = run(keys + ' CHAR:x ENTER', 'clear')
assert 'result=0' in out and 'order=0,1,3,4,2,5' in out and 'filters= ' in out, out
print('ok')
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"ok"* ]]
}
