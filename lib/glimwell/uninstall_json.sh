#!/bin/bash
# Glimwell: the machine interface the Glimwell Mac app uses for Uninstall.
#
#   glimwell uninstall --list --json                  the app list, one JSON array
#   glimwell uninstall --dry-run --json --only FILE   preview, one JSON object per line
#   glimwell uninstall --json --only FILE             uninstall exactly what FILE lists
#
# FILE holds "app:<path of the .app>" lines and, for a real run, the
# "path:<leftover>" lines the user kept ticked. An app is uninstalled only when
# its exact path is listed and the CLI's own app list holds it. A leftover is
# removed only when it is listed and this run's own fresh scan of a listed app
# finds it again. Every check of a terminal uninstall still runs, except that
# nothing is quit, nothing asks for a password and nothing uses sudo; such an
# app is kept and reported instead.
#
# Where this is enforced, each place marked "glimwell:":
#   bin/uninstall.sh main            flags, refusals, routing to this file
#   validate_path_for_deletion       refuses any path but the app in hand and
#     (file_ops.sh)                  its listed, rescanned leftovers
#   _batch_execute_removals          a running app or one that needs a password
#     (batch.sh)                     is kept before any teardown; nothing is quit
#   _mole_move_to_trash              moves straight into ~/.Trash, never through
#     (file_ops.sh)                  Finder, whose fallback can ask for a password
#   _mole_complete_lsof_mode         never adopts a cached sudo session
#   brew_uninstall_cask (brew.sh)    brew runs with an askpass that refuses
#   log_operation (log.sh) and _mole_record_uninstall_refusal (file_ops.sh)
#                                    report removed and kept paths as events

GLIMWELL_UNINSTALL_JSON=0
_GLIMWELL_UJ_DRY=0
_GLIMWELL_UJ_SUMMARY_SENT=0
_GLIMWELL_UJ_CANCEL=0
# Selection read from --only. Arrays never come from the environment, and
# they are reset here so nothing but that file can fill them.
_GLIMWELL_UJ_SEL_APPS=()
_GLIMWELL_UJ_SEL_PATHS=()
# The deletion funnel's allowlist: the app in hand and its chosen leftovers.
# While inactive, a JSON real run refuses every path.
_GLIMWELL_UJ_ALLOW=()
_GLIMWELL_UJ_ALLOW_ACTIVE=0
# The app whose removal is in hand, and what has been reported for it.
_GLIMWELL_UJ_APP=""
_GLIMWELL_UJ_REPORTED=()
_GLIMWELL_UJ_REASON_CODE=""
_GLIMWELL_UJ_LAST_REASON=""
_GLIMWELL_UJ_BREW_NEEDS_ADMIN=0
_GLIMWELL_UJ_APP_ATTEMPTED=0
# Counts for the summary.
_GLIMWELL_UJ_N_APPS=0
_GLIMWELL_UJ_N_ITEMS=0
_GLIMWELL_UJ_N_REMOVED=0
_GLIMWELL_UJ_N_KEPT=0
_GLIMWELL_UJ_N_APPS_KEPT=0
# The funnel's probe exemption is set only as a local by can_unload_launch_plist.
_GLIMWELL_UJ_UNLOAD_PROBE=0
# Values inherited from the environment were reset above; none is passed on.
for _glimwell_uj_var in GLIMWELL_UNINSTALL_JSON ${!_GLIMWELL_UJ_@}; do
    export -n "${_glimwell_uj_var?}" 2> /dev/null || true
done
unset _glimwell_uj_var

glimwell_uninstall_json_emit() {
    [[ "$GLIMWELL_UNINSTALL_JSON" == "1" ]] || return 0
    printf '%s\n' "$1" 2> /dev/null >&8 || true
}

# Strip trailing slashes into the variable named by $1.
_glimwell_uj_norm() {
    local __v="${2-}"
    while [[ "$__v" == */ && "$__v" != / ]]; do __v="${__v%/}"; done
    printf -v "$1" '%s' "$__v"
}

# An absolute path below a top-level folder, with no empty, "." or ".."
# component and no control character.
_glimwell_uj_plain_path() {
    local p="$1" dots='(^|/)\.\.?(/|$)'
    [[ "$p" == /?*/?* && "$p" != *//* ]] || return 1
    [[ ! "$p" =~ $dots ]] || return 1
    local LC_ALL=C
    [[ ! "$p" =~ [[:cntrl:]] ]] || return 1
    return 0
}

_glimwell_uj_in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# A selection file holding a NUL byte is refused: bash drops NULs while
# reading, so the line it saw would differ from the bytes on disk.
glimwell_selection_file_has_nul() {
    local nul_count=""
    nul_count=$(LC_ALL=C /usr/bin/tr -cd '\000' < "$1" 2> /dev/null | /usr/bin/wc -c) || return 0
    nul_count="${nul_count//[[:space:]]/}"
    [[ "$nul_count" != "0" ]]
}

_glimwell_uj_refuse() {
    printf 'glimwell uninstall: %s\n' "$1" >&2
    return 1
}

# Read and check the --only file. DRY is 1 for a preview, which ignores
# "path:" lines.
glimwell_uninstall_selection_load() {
    local file="$1" dry="${2:-0}"
    _GLIMWELL_UJ_SEL_APPS=()
    _GLIMWELL_UJ_SEL_PATHS=()
    if [[ -z "$file" || (! -e "$file" && ! -L "$file") ]]; then
        _glimwell_uj_refuse "--only: the selection file was not found: $file"
        return 1
    fi
    if [[ -L "$file" || ! -f "$file" || ! -r "$file" ]]; then
        _glimwell_uj_refuse "--only: the selection must be a readable regular file, not a link or folder: $file"
        return 1
    fi
    if glimwell_selection_file_has_nul "$file"; then
        _glimwell_uj_refuse "--only: the selection file holds a NUL byte."
        return 1
    fi
    local line="" number=0 value=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        [[ -n "$line" ]] || continue
        if (
            LC_ALL=C
            [[ "$line" =~ [[:cntrl:]] ]]
        ); then
            _glimwell_uj_refuse "--only: line $number holds a control character."
            return 1
        fi
        case "$line" in
            app:*)
                _glimwell_uj_norm value "${line#app:}"
                if ! _glimwell_uj_plain_path "$value" || [[ "$value" != *.[aA][pP][pP] ]]; then
                    _glimwell_uj_refuse "--only: line $number is not the absolute path of an .app bundle."
                    return 1
                fi
                _glimwell_uj_in_list "$value" "${_GLIMWELL_UJ_SEL_APPS[@]+"${_GLIMWELL_UJ_SEL_APPS[@]}"}" ||
                    _GLIMWELL_UJ_SEL_APPS+=("$value")
                ;;
            path:*)
                _glimwell_uj_norm value "${line#path:}"
                if ! _glimwell_uj_plain_path "$value"; then
                    _glimwell_uj_refuse "--only: line $number is not a plain absolute path below a top-level folder."
                    return 1
                fi
                [[ "$dry" == "1" ]] && continue
                _glimwell_uj_in_list "$value" "${_GLIMWELL_UJ_SEL_PATHS[@]+"${_GLIMWELL_UJ_SEL_PATHS[@]}"}" ||
                    _GLIMWELL_UJ_SEL_PATHS+=("$value")
                ;;
            *)
                _glimwell_uj_refuse "--only: line $number is neither \"app:/...\" nor \"path:/...\". Use the IDs from glimwell uninstall --dry-run --json."
                return 1
                ;;
        esac
    done < "$file"
    if [[ ${#_GLIMWELL_UJ_SEL_APPS[@]} -eq 0 ]]; then
        if [[ ${#_GLIMWELL_UJ_SEL_PATHS[@]} -gt 0 ]]; then
            _glimwell_uj_refuse "--only: the selection lists leftovers but no app; leftovers go only with their app."
        else
            _glimwell_uj_refuse "--only: the selection file lists no app."
        fi
        return 1
    fi
    return 0
}

# The deletion funnel asks this for every path of a JSON real run. Returns 0
# (refuse) unless the path is the app in hand or one of its chosen leftovers,
# or lies inside one of them.
glimwell_uninstall_refuses_path() {
    [[ "$_GLIMWELL_UJ_ALLOW_ACTIVE" == "1" ]] || return 0
    local p="" allowed=""
    _glimwell_uj_norm p "$1"
    for allowed in "${_GLIMWELL_UJ_ALLOW[@]+"${_GLIMWELL_UJ_ALLOW[@]}"}"; do
        [[ -n "$allowed" ]] || continue
        [[ "$p" == "$allowed" || "$p" == "$allowed"/* ]] && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

_glimwell_uj_q() {
    if [[ -z "${2-}" ]]; then
        printf -v "$1" 'null'
    else
        glimwell_json_quote "$1" "$2"
    fi
}

_glimwell_uj_num() {
    if [[ "${2-}" =~ ^[0-9]+$ ]]; then
        printf -v "$1" '%s' "$2"
    else
        printf -v "$1" 'null'
    fi
}

_glimwell_uj_reported() {
    _glimwell_uj_in_list "$1" "${_GLIMWELL_UJ_REPORTED[@]+"${_GLIMWELL_UJ_REPORTED[@]}"}"
}

_glimwell_uj_emit_removed() {
    local path="$1" detail="${2:-}" q_app q_path q_detail
    _glimwell_uj_reported "$path" && return 0
    _GLIMWELL_UJ_REPORTED+=("$path")
    _GLIMWELL_UJ_N_REMOVED=$((_GLIMWELL_UJ_N_REMOVED + 1))
    _glimwell_uj_q q_app "$_GLIMWELL_UJ_APP"
    _glimwell_uj_q q_path "$path"
    _glimwell_uj_q q_detail "$detail"
    glimwell_uninstall_json_emit "{\"type\":\"removed\",\"app\":$q_app,\"path\":$q_path,\"detail\":$q_detail}"
}

_glimwell_uj_emit_kept() {
    local path="$1" reason="$2" detail="${3:-}" q_app q_path q_detail
    _glimwell_uj_reported "$path" && return 0
    _GLIMWELL_UJ_REPORTED+=("$path")
    _GLIMWELL_UJ_N_KEPT=$((_GLIMWELL_UJ_N_KEPT + 1))
    _glimwell_uj_q q_app "$_GLIMWELL_UJ_APP"
    _glimwell_uj_q q_path "$path"
    _glimwell_uj_q q_detail "$detail"
    glimwell_uninstall_json_emit "{\"type\":\"kept\",\"app\":$q_app,\"path\":$q_path,\"reason\":\"$reason\",\"detail\":$q_detail}"
}

# A size the CLI logged as "<KB>KB" becomes display text; anything else is
# not a size.
_glimwell_uj_size_detail() {
    local __detail="${2-}"
    if [[ "$__detail" =~ ^([0-9]+)KB$ ]]; then
        printf -v "$1" '%s' "$(bytes_to_human "$((BASH_REMATCH[1] * 1024))")"
    else
        printf -v "$1" '%s' ""
    fi
}

# log_operation calls this for every row while a JSON run is active.
glimwell_uninstall_json_operation() {
    [[ "$GLIMWELL_UNINSTALL_JSON" == "1" && "$_GLIMWELL_UJ_DRY" != "1" ]] || return 0
    [[ -n "$_GLIMWELL_UJ_APP" ]] || return 0
    local action="$1" path="$2" detail="${3:-}" display="" reason=""
    # Login items and Dock entries are logged by name, not as files.
    [[ "$path" == /* ]] || return 0
    case "$action" in
        REMOVED | TRASHED)
            # Unloading a launch agent or booting out a helper logs REMOVED
            # for a file that stays where it is.
            case "$detail" in
                "launchctl unload" | "launchctl bootout" | "brew autoremove" | "login item" | "dock entry") return 0 ;;
            esac
            _glimwell_uj_size_detail display "$detail"
            _glimwell_uj_emit_removed "$path" "$display"
            return 0
            ;;
        SKIPPED | FAILED) ;;
        *) return 0 ;;
    esac
    case "$detail" in
        "not selected") return 0 ;;
        "selected app path reappeared" | "agent ownership unverified" | "identity changed" | "path identity unavailable")
            reason="changed"
            ;;
        "privacy permission denied") reason="access_denied" ;;
        "trash-failed") reason="trash_failed" ;;
        "mutable-parent") reason="needs_admin" ;;
        "live user cache" | "active or unknown SQLite database" | "active or unknown download") reason="in_use" ;;
        *)
            if [[ "$action" == "FAILED" ]]; then
                reason="failed"
            else
                reason="protected"
            fi
            ;;
    esac
    _glimwell_uj_emit_kept "$path" "$reason" "$detail"
}

# _mole_record_uninstall_refusal calls this with the refusal cause it records.
glimwell_uninstall_json_refusal() {
    [[ "$GLIMWELL_UNINSTALL_JSON" == "1" && "$_GLIMWELL_UJ_DRY" != "1" ]] || return 0
    [[ -n "$_GLIMWELL_UJ_APP" && -n "${1:-}" ]] || return 0
    local reason="protected" detail=""
    case "${2:-}" in
        live-cache) reason="in_use" detail="the app may be using it" ;;
        access-denied) reason="access_denied" detail="macOS denied access" ;;
        ownership-unverified) reason="changed" detail="ownership could not be verified" ;;
        app-reappeared) reason="changed" detail="the app is back at its path" ;;
        shared-owner) reason="protected" detail="shared with another installed copy of the app" ;;
        owner-unknown) reason="protected" detail="other copies of the app could not be checked" ;;
        *) detail="${2:-}" ;;
    esac
    _glimwell_uj_emit_kept "$1" "$reason" "$detail"
}

# brew_uninstall_cask hands over brew's output from a JSON run.
glimwell_uninstall_json_note_brew_output() {
    local log="$1"
    _GLIMWELL_UJ_BREW_NEEDS_ADMIN=0
    [[ -f "$log" ]] || return 0
    if LC_ALL=C /usr/bin/grep -q 'sudo: ' "$log" 2> /dev/null; then
        _GLIMWELL_UJ_BREW_NEEDS_ADMIN=1
    fi
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        cat "$log" >&2 2> /dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# App checks
# ---------------------------------------------------------------------------

# `brew uninstall --cask` also runs the cask's own uninstall steps: it can
# quit or signal apps, unload agents, run vendor scripts and delete paths the
# user never saw. The app's runs take only casks whose artifacts are the one
# app bundle plus links (binaries, man pages, completions); zap steps never run
# without --zap. Returns 0 for such a cask, 1 for any other, 2 when Homebrew's
# description could not be read.
glimwell_uninstall_cask_is_plain() {
    local cask="$1" app_path="$2" info="" info_rc=0
    _mole_brew_info_token_is_storable "$cask" || return 2
    info=$(_mole_brew_probe "$MOLE_TIMEOUT_PKG_LIST_SEC" info --cask --json=v2 "$cask" 2> /dev/null < /dev/null) || info_rc=$?
    mole_rc_signal "$info_rc" && return "$info_rc"
    [[ $info_rc -eq 0 && -n "$info" ]] || return 2
    local verdict_rc=0
    # shellcheck disable=SC2016  # Perl code, not shell expansion.
    printf '%s' "$info" | APP_BASE="${app_path##*/}" /usr/bin/perl -MJSON::PP -e '
        my $d = eval { local $/; JSON::PP->new->decode(<STDIN>) } or exit 2;
        my $casks = $d->{casks};
        exit 2 unless ref $casks eq "ARRAY" && @$casks == 1;
        my $arts = $casks->[0]{artifacts};
        exit 2 unless ref $arts eq "ARRAY";
        my %plain = map { $_ => 1 } qw(app binary manpage bash_completion zsh_completion fish_completion zap);
        my $apps = 0;
        for my $a (@$arts) {
            exit 2 unless ref $a eq "HASH";
            for my $k (keys %$a) {
                exit 1 unless $plain{$k};
                next unless $k eq "app";
                for my $e (@{ ref $a->{$k} eq "ARRAY" ? $a->{$k} : [] }) {
                    my $src = ref $e eq "ARRAY" ? $e->[0] : $e;
                    my $target = (ref $e eq "ARRAY" && ref $e->[1] eq "HASH") ? $e->[1]{target} : undef;
                    my $name = defined $target ? $target : $src;
                    next unless defined $name && !ref $name;
                    $name =~ s{.*/}{};
                    exit 1 unless $name eq $ENV{APP_BASE};
                    $apps++;
                }
            }
        }
        exit($apps == 1 ? 0 : 1);
    ' > /dev/null 2>&1 || verdict_rc=$?
    return "$verdict_rc"
}

# Open now: a process runs an executable from the bundle's Contents/MacOS
# (helpers elsewhere in the bundle do not count), or one named like its
# CFBundleExecutable runs, as the terminal preview checks.
glimwell_uninstall_app_is_running() {
    local app_path="${1%/}" app_name="${2:-}" comm="" prefix=""
    prefix="$app_path/Contents/MacOS/"
    mole_is_playcover_app "$app_path" 2> /dev/null && prefix="$app_path/"
    while IFS= read -r comm; do
        comm="${comm#"${comm%%[! ]*}"}"
        [[ "$comm" == "$prefix"* ]] && return 0
    done < <(/bin/ps -axww -o comm= 2> /dev/null)
    local info="$app_path/Contents/Info.plist" exec_name=""
    mole_is_playcover_app "$app_path" 2> /dev/null && info="$app_path/Info.plist"
    if [[ -e "$info" ]]; then
        exec_name=$(plutil -extract CFBundleExecutable raw "$info" 2> /dev/null || echo "")
    fi
    _uninstall_app_running_by_executable "$app_name" "$exec_name" && return 0
    return 1
}

# Called by _batch_execute_removals before teardown and again before the app
# moves. Sets the caller's `reason` (dynamic scope) and the reason code.
glimwell_uninstall_json_guard_app() {
    [[ "$GLIMWELL_UNINSTALL_JSON" == "1" ]] || return 0
    local app_name="$1" app_path="$2" needs_sudo="${3:-false}"
    if [[ "$needs_sudo" == "true" ]]; then
        reason="removing it needs an administrator password"
        _GLIMWELL_UJ_REASON_CODE="needs_admin"
        return 0
    fi
    if glimwell_uninstall_app_is_running "$app_path" "$app_name"; then
        reason="the app is open"
        _GLIMWELL_UJ_REASON_CODE="running"
    fi
    return 0
}

# The JSON reason code for an app-level failure text from the batch.
_glimwell_uj_reason_code() {
    local __text="${2-}" __code="failed"
    if [[ -n "$_GLIMWELL_UJ_REASON_CODE" ]]; then
        __code="$_GLIMWELL_UJ_REASON_CODE"
    else
        case "$__text" in
            *"changed after preview"* | *"installation set changed"*) __code="changed" ;;
            "parent directory not writable" | *"elevated deletion"* | *"authentication"*) __code="needs_admin" ;;
            *"denied"*) __code="access_denied" ;;
            "brew uninstall failed"*)
                [[ "$_GLIMWELL_UJ_BREW_NEEDS_ADMIN" == "1" ]] && __code="needs_admin"
                ;;
            *"protected"*) __code="protected" ;;
        esac
    fi
    printf -v "$1" '%s' "$__code"
}

# Folder kind for display: the Library folder holding the path.
_glimwell_uj_label() {
    local __path="$1" __rest="" __label=""
    case "$__path" in
        "$HOME/Library/"*)
            __rest="${__path#"$HOME/Library/"}"
            __label="${__rest%%/*}"
            ;;
        "$HOME/".*) __label="Home folder" ;;
        "$HOME/"*)
            __rest="${__path#"$HOME/"}"
            __label="${__rest%%/*}"
            ;;
        /Library/*)
            __rest="${__path#/Library/}"
            __label="${__rest%%/*}"
            ;;
        *) __label="" ;;
    esac
    printf -v "$2" '%s' "$__label"
}

# caution: shared (another app may use it), library (the user's own content
# such as browser profiles, VMs, game or emulator libraries) or empty.
_glimwell_uj_caution() {
    local __path="$1" __lower="" __home=""
    mole_ascii_lowercase __lower "$__path"
    mole_ascii_lowercase __home "$HOME"
    case "$__lower" in
        "$__home/library/group containers/"*)
            printf -v "$2" 'shared'
            return 0
            ;;
    esac
    if _uninstall_data_preselect_holdback "$__path"; then
        printf -v "$2" 'library'
    else
        printf -v "$2" '%s' ""
    fi
}

# ---------------------------------------------------------------------------
# --list --json
# ---------------------------------------------------------------------------

glimwell_uninstall_json_list() {
    local apps_file=""
    if ! apps_file=$(scan_applications); then
        printf 'glimwell uninstall: could not complete the application scan\n' >&2
        return 1
    fi
    if [[ ! -f "$apps_file" ]]; then
        printf 'glimwell uninstall: the application scan produced no list\n' >&2
        return 1
    fi
    apps_data=()
    load_applications "$apps_file" > /dev/null 2>&1 || true
    rm -f "$apps_file" "${apps_file}.inventory" # SAFE: exact scan output and inventory sidecar

    local _MOLE_BREW_BATCH_LIST_READY=0 _MOLE_BREW_BATCH_LIST="" _MOLE_BREW_BATCH_LIST_RC=0
    local _MOLE_BREW_BATCH_ROOM_READY=0 _MOLE_BREW_BATCH_ROOM_FILE="" _MOLE_BREW_BATCH_ROOM_RC=0
    local _MOLE_BREW_BATCH_INFO_READY=0 _MOLE_BREW_BATCH_INFO_DIR=""
    local brew_inventory_dir="" brew_prep_rc=0 brew_ok=0
    if is_homebrew_available && brew_inventory_dir=$(create_temp_dir); then
        brew_ok=1
        _MOLE_BREW_BATCH_ROOM_FILE="$brew_inventory_dir/caskroom"
        _mole_brew_prepare_batch_inventory > /dev/null 2>&1 || brew_prep_rc=$?
        if [[ $brew_prep_rc -lt 128 ]]; then
            local -a brew_app_paths=()
            local brew_row brew_path
            for brew_row in "${apps_data[@]+"${apps_data[@]}"}"; do
                IFS='|' read -r _ brew_path _ <<< "$brew_row"
                [[ -n "$brew_path" ]] && brew_app_paths+=("$brew_path")
            done
            _MOLE_BREW_BATCH_INFO_DIR="$brew_inventory_dir/info"
            mkdir -p "$_MOLE_BREW_BATCH_INFO_DIR" || _MOLE_BREW_BATCH_INFO_DIR=""
            if [[ -n "$_MOLE_BREW_BATCH_INFO_DIR" && ${#brew_app_paths[@]} -gt 0 ]]; then
                _mole_brew_prefetch_cask_info "${brew_app_paths[@]}" > /dev/null 2>&1 || brew_prep_rc=$?
            fi
        fi
        if [[ $brew_prep_rc -ge 128 ]]; then
            rm -rf -- "$brew_inventory_dir" # SAFE: private read-only Homebrew inventory directory created above
            return "$brew_prep_rc"
        fi
    fi

    local out="[" first=1 row epoch app_path app_name bundle_id size last_used size_kb
    local cask="" q_name q_bundle q_source q_un q_path q_size q_cask n_bytes n_used
    for row in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$row"
        cask=""
        if [[ $brew_ok -eq 1 ]]; then
            cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
        fi
        glimwell_json_quote q_name "$app_name"
        glimwell_json_quote q_bundle "$bundle_id"
        if [[ -n "$cask" ]]; then q_source='"Homebrew"'; else q_source='"App"'; fi
        glimwell_json_quote q_un "${cask:-$app_name}"
        glimwell_json_quote q_path "$app_path"
        glimwell_json_quote q_size "$(uninstall_normalize_size_display "$size" "$app_path")"
        _glimwell_uj_q q_cask "$cask"
        n_bytes="null"
        if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
            n_bytes=$((size_kb * 1024))
        fi
        n_used="null"
        if [[ "$epoch" =~ ^[0-9]+$ && "$epoch" -gt 0 ]]; then
            n_used="$epoch"
        fi
        if [[ $first -eq 1 ]]; then
            first=0
            out+=$'\n'
        else
            out+=$',\n'
        fi
        out+="  {\"name\":$q_name,\"bundle_id\":$q_bundle,\"source\":$q_source,\"uninstall_name\":$q_un,\"path\":$q_path,\"size\":$q_size,\"bytes\":$n_bytes,\"last_used\":$n_used,\"cask\":$q_cask}"
    done
    [[ $first -eq 1 ]] || out+=$'\n'
    out+="]"
    printf '%s\n' "$out"
    [[ -z "$brew_inventory_dir" ]] || rm -rf -- "$brew_inventory_dir" # SAFE: private read-only Homebrew inventory directory created above
    return 0
}

# ---------------------------------------------------------------------------
# Preview and real run
# ---------------------------------------------------------------------------

_glimwell_uj_summary() {
    local status="$1" exit_code="$2" dry="true"
    [[ "$_GLIMWELL_UJ_SUMMARY_SENT" == "1" ]] && return 0
    _GLIMWELL_UJ_SUMMARY_SENT=1
    [[ "$_GLIMWELL_UJ_DRY" == "1" ]] || dry="false"
    if [[ "$_GLIMWELL_UJ_DRY" == "1" ]]; then
        glimwell_uninstall_json_emit "{\"type\":\"summary\",\"dry_run\":true,\"status\":\"$status\",\"exit\":$exit_code,\"apps\":$_GLIMWELL_UJ_N_APPS,\"items\":$_GLIMWELL_UJ_N_ITEMS}"
    else
        glimwell_uninstall_json_emit "{\"type\":\"summary\",\"dry_run\":false,\"status\":\"$status\",\"exit\":$exit_code,\"apps\":$_GLIMWELL_UJ_N_APPS,\"removed\":$_GLIMWELL_UJ_N_REMOVED,\"kept\":$_GLIMWELL_UJ_N_KEPT}"
    fi
}

_glimwell_uj_error() {
    local q=""
    glimwell_json_quote q "$1"
    glimwell_uninstall_json_emit "{\"type\":\"error\",\"message\":$q}"
}

# The EXIT handler of bin/uninstall.sh calls this, so a run that stops early
# still ends with a summary.
glimwell_uninstall_json_on_exit() {
    [[ "$GLIMWELL_UNINSTALL_JSON" == "1" ]] || return 0
    local code="${1:-1}"
    case "$code" in
        130 | 143) _glimwell_uj_summary cancelled "$code" ;;
        0) _glimwell_uj_summary complete 0 ;;
        *) _glimwell_uj_summary failed "$code" ;;
    esac
}

# Find the inventory row of each listed app, then scan the uninstallable ones
# exactly as the terminal batch does. Fills, in the caller's scope:
# _gw_status[i], _gw_note[i], _gw_row[i] per listed app, and the batch arrays.
_glimwell_uj_classify_and_scan() {
    local apps_file=""
    # The scan leaves a metadata refresh running in the background; without
    # fd 8 it cannot hold the event stream open after the summary.
    if ! apps_file=$(scan_applications 8>&-); then
        _glimwell_uj_error "Could not complete the application scan; nothing was changed."
        return 1
    fi
    apps_data=()
    if [[ -f "$apps_file" ]]; then
        load_applications "$apps_file" > /dev/null 2>&1 || true
        rm -f "$apps_file" "${apps_file}.inventory" # SAFE: exact scan output and inventory sidecar
    fi

    local i=0 listed row row_path found bundle
    selected_apps=()
    for listed in "${_GLIMWELL_UJ_SEL_APPS[@]}"; do
        found=""
        for row in "${apps_data[@]+"${apps_data[@]}"}"; do
            IFS='|' read -r _ row_path _ <<< "$row"
            if [[ "$row_path" == "$listed" ]]; then
                found="$row"
                break
            fi
        done
        _gw_row[i]="$found"
        _gw_note[i]=""
        if [[ -z "$found" ]]; then
            if [[ ! -e "$listed" && ! -L "$listed" ]]; then
                _gw_status[i]="missing"
                _gw_note[i]="No app is at this path."
            else
                bundle=$(uninstall_resolve_bundle_id "$listed" 2> /dev/null || true)
                if [[ -n "$bundle" ]] && should_protect_from_uninstall "$bundle"; then
                    _gw_status[i]="protected"
                    _gw_note[i]="A macOS system app."
                else
                    _gw_status[i]="manual"
                    _gw_note[i]="Not in Glimwell's app list; move it to the Trash in Finder."
                fi
            fi
        elif uninstall_app_is_steam_launcher "$listed"; then
            _gw_status[i]="steam"
            _gw_note[i]="Steam manages this game; uninstall it in Steam."
        else
            _gw_status[i]="scan"
            selected_apps+=("$found")
        fi
        i=$((i + 1))
    done

    [[ ${#selected_apps[@]} -gt 0 ]] || return 0
    local _scan_rc=0
    _batch_scan_app_details > /dev/null || _scan_rc=$?
    if mole_rc_signal "$_scan_rc"; then
        return "$_scan_rc"
    elif mole_rc_timeout "$_scan_rc"; then
        _glimwell_uj_error "The uninstall scan timed out before finishing; nothing was changed."
        return 1
    elif [[ $_scan_rc -ne 0 ]]; then
        local message="Could not finish the uninstall scan ($_batch_scan_stage, exit $_scan_rc); nothing was changed."
        if [[ "$_batch_scan_stage" == "Homebrew ownership check" && -n "$_batch_scan_app_name" ]]; then
            message="Homebrew could not read the cask of $_batch_scan_app_name; run brew info --cask for it. Nothing was changed."
        fi
        _glimwell_uj_error "$message"
        return 1
    fi

    # Settle each scanned app: in app_details it can be uninstalled; otherwise
    # the scan put it on the blocked or manual list.
    local detail d_path blocked_entry
    i=0
    for listed in "${_GLIMWELL_UJ_SEL_APPS[@]}"; do
        if [[ "${_gw_status[i]}" == "scan" ]]; then
            _gw_status[i]=""
            for detail in "${app_details[@]+"${app_details[@]}"}"; do
                IFS='|' read -r _ d_path _ <<< "$detail"
                if [[ "$d_path" == "$listed" ]]; then
                    _gw_status[i]="ok"
                    _gw_detail[i]="$detail"
                    break
                fi
            done
            if [[ "${_gw_status[i]}" == "ok" ]]; then
                local c_brew="" c_cask="" cask_rc=0
                IFS='|' read -r _ _ _ _ _ _ _ _ c_brew c_cask _ <<< "${_gw_detail[i]}"
                if [[ "$c_brew" == "true" && -n "$c_cask" ]]; then
                    glimwell_uninstall_cask_is_plain "$c_cask" "$listed" || cask_rc=$?
                    mole_rc_signal "$cask_rc" && return "$cask_rc"
                    if [[ $cask_rc -ne 0 ]]; then
                        _gw_status[i]="manual"
                        if [[ $cask_rc -eq 1 ]]; then
                            _gw_note[i]="Its Homebrew cask runs uninstall steps of its own; run brew uninstall --cask $c_cask in Terminal."
                        else
                            _gw_note[i]="Homebrew's description of the $c_cask cask could not be read; run brew uninstall --cask $c_cask in Terminal."
                        fi
                    fi
                fi
            fi
            if [[ -z "${_gw_status[i]}" ]]; then
                local app_name=""
                IFS='|' read -r _ _ app_name _ <<< "${_gw_row[i]}"
                _gw_status[i]="manual"
                _gw_note[i]="Glimwell can't remove it safely from this location; move it to the Trash in Finder."
                for blocked_entry in "${blocked_apps[@]+"${blocked_apps[@]}"}"; do
                    if [[ "${blocked_entry%%|*}" == "$app_name" ]]; then
                        _gw_status[i]="blocked"
                        _gw_note[i]="Use the official ${blocked_entry#*|} uninstaller."
                        break
                    fi
                done
            fi
        fi
        i=$((i + 1))
    done
    return 0
}

# The scanned leftovers of one app detail, without nested paths, one per line.
_glimwell_uj_detail_leftovers() {
    local detail="$1" name encoded files path
    IFS='|' read -r name _ _ _ encoded _ <<< "$detail"
    files=$(decode_file_list "$encoded" "$name")
    local -a paths=()
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        _glimwell_uj_norm path "$path"
        paths+=("$path")
    done <<< "$files"
    [[ ${#paths[@]} -gt 0 ]] || return 0
    mole_filter_nested_paths "${paths[@]}"
}

_glimwell_uj_emit_app() {
    local listed="$1" status="$2" note="$3" row="$4" detail="$5"
    local name="" bundle="" kb="" cask="" running="false" needs_admin="false" bundle_only="false"
    if [[ -n "$detail" ]]; then
        local d_name d_path d_bundle d_kb d_files d_sys d_sens d_sudo d_brew d_cask d_diag d_review d_login d_guard d_ident d_orig
        IFS='|' read -r d_name d_path d_bundle d_kb d_files d_sys d_sens d_sudo d_brew d_cask d_diag d_review d_login d_guard d_ident d_orig _ <<< "$detail"
        name="$d_name"
        bundle="${d_orig:-$d_bundle}"
        [[ "$bundle" != "unknown" ]] || bundle=""
        kb="$d_kb"
        cask="$d_cask"
        [[ "$d_sudo" == "true" ]] && needs_admin="true"
        if [[ "${d_guard:-none}" != "none" && -z "$d_files" ]]; then
            bundle_only="true"
        fi
        local leftover_note
        for leftover_note in "${leftover_notes[@]+"${leftover_notes[@]}"}"; do
            [[ "${leftover_note%%|*}" == "$listed" ]] || continue
            [[ -z "$note" ]] || note+="; "
            note+="${leftover_note#*|}"
        done
    elif [[ -n "$row" ]]; then
        local r_size_kb
        IFS='|' read -r _ _ name bundle _ _ r_size_kb <<< "$row"
        kb="$r_size_kb"
    fi
    if [[ -z "$name" ]]; then
        name="${listed##*/}"
        name="${name%.[aA][pP][pP]}"
    fi
    if [[ "$status" == "ok" || -n "$row" ]] && [[ -e "$listed" ]] &&
        glimwell_uninstall_app_is_running "$listed" "$name"; then
        running="true"
    fi
    local q_app q_name q_bundle q_cask q_note n_bytes=null
    glimwell_json_quote q_app "$listed"
    glimwell_json_quote q_name "$name"
    _glimwell_uj_q q_bundle "$bundle"
    _glimwell_uj_q q_cask "$cask"
    _glimwell_uj_q q_note "$note"
    if [[ "$kb" =~ ^[0-9]+$ && "$kb" -gt 0 ]]; then
        n_bytes=$((kb * 1024))
    fi
    glimwell_uninstall_json_emit "{\"type\":\"app\",\"app\":$q_app,\"name\":$q_name,\"bundle_id\":$q_bundle,\"bytes\":$n_bytes,\"cask\":$q_cask,\"status\":\"$status\",\"running\":$running,\"needs_admin\":$needs_admin,\"bundle_only\":$bundle_only,\"note\":$q_note}"
}

glimwell_uninstall_json_preview() {
    local -a _gw_status=() _gw_note=() _gw_row=() _gw_detail=()
    local -a running_apps=() sudo_apps=() brew_cask_apps=() blocked_apps=()
    local -a manual_removal_apps=() leftover_notes=() app_details=()
    local total_estimated_size=0 _batch_scan_stage="application inspection" _batch_scan_app_name=""
    local rc=0
    _glimwell_uj_classify_and_scan || rc=$?
    if [[ $rc -ne 0 ]]; then
        mole_rc_signal "$rc" && return "$rc"
        return 1
    fi

    local i=0 listed status detail path kind preselect caution label size_kb size_rc
    local q_id q_app q_path q_label q_caution n_bytes review_name review_encoded reviews
    # A leftover two listed apps share is offered once, under the first.
    local -a offered=()
    for listed in "${_GLIMWELL_UJ_SEL_APPS[@]}"; do
        [[ $_GLIMWELL_UJ_CANCEL -eq 0 ]] || return "$_GLIMWELL_UJ_CANCEL"
        status="${_gw_status[i]}"
        detail="${_gw_detail[i]:-}"
        _glimwell_uj_emit_app "$listed" "$status" "${_gw_note[i]}" "${_gw_row[i]}" "$detail"
        if [[ "$status" == "ok" ]]; then
            _GLIMWELL_UJ_N_APPS=$((_GLIMWELL_UJ_N_APPS + 1))
            glimwell_json_quote q_app "$listed"
            while IFS= read -r path; do
                [[ -n "$path" ]] || continue
                [[ $_GLIMWELL_UJ_CANCEL -eq 0 ]] || return "$_GLIMWELL_UJ_CANCEL"
                _glimwell_uj_in_list "$path" "${offered[@]+"${offered[@]}"}" && continue
                offered+=("$path")
                if _uninstall_disposable_leftover "$path"; then
                    kind="cache" preselect="true"
                else
                    kind="data" preselect="false"
                fi
                _glimwell_uj_caution "$path" caution
                _glimwell_uj_label "$path" label
                n_bytes="null"
                if ! mole_sizing_would_ask_for_app_data "$path"; then
                    size_rc=0
                    size_kb=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
                    mole_rc_signal "$size_rc" && return "$size_rc"
                    if [[ $size_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]]; then
                        n_bytes=$((size_kb * 1024))
                    fi
                fi
                glimwell_json_quote q_id "path:$path"
                glimwell_json_quote q_path "$path"
                _glimwell_uj_q q_label "$label"
                _glimwell_uj_q q_caution "$caution"
                glimwell_uninstall_json_emit "{\"type\":\"item\",\"id\":$q_id,\"app\":$q_app,\"kind\":\"$kind\",\"label\":$q_label,\"path\":$q_path,\"bytes\":$n_bytes,\"preselect\":$preselect,\"caution\":$q_caution}"
                _GLIMWELL_UJ_N_ITEMS=$((_GLIMWELL_UJ_N_ITEMS + 1))
            done < <(_glimwell_uj_detail_leftovers "$detail")
            IFS='|' read -r review_name _ _ _ _ _ _ _ _ _ _ review_encoded _ <<< "$detail"
            reviews=$(decode_file_list "$review_encoded" "$review_name")
            while IFS= read -r path; do
                [[ -n "$path" ]] || continue
                glimwell_json_quote q_path "$path"
                glimwell_uninstall_json_emit "{\"type\":\"review\",\"app\":$q_app,\"path\":$q_path,\"reason\":\"system\"}"
            done <<< "$reviews"
        fi
        i=$((i + 1))
    done
    return 0
}

# Report what one app's removal left and emit app_done.
_glimwell_uj_finish_app() {
    local listed="$1" failed_reason="$2"
    shift 2
    local code="" path
    if [[ -n "$failed_reason" ]]; then
        _glimwell_uj_reason_code code "$failed_reason"
    fi
    local bundle_gone=false
    if [[ "${_GLIMWELL_UJ_APP_ATTEMPTED:-0}" == "1" && ! -e "$listed" && ! -L "$listed" ]]; then
        bundle_gone=true
    fi
    if [[ "$bundle_gone" == true ]]; then
        # Homebrew may remove the bundle and still fail on a later step; no
        # sink logged that removal, so log it here (the hook reports it).
        _glimwell_uj_reported "$listed" ||
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "REMOVED" "$listed" "brew uninstall"
        _glimwell_uj_emit_removed "$listed" ""
    else
        _glimwell_uj_emit_kept "$listed" "${code:-failed}" "$failed_reason"
    fi
    local leftovers_kept=0
    for path in "$@"; do
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ "$bundle_gone" == true && -z "$failed_reason" ]]; then
                _glimwell_uj_emit_kept "$path" "failed" ""
            elif [[ "$bundle_gone" == true ]]; then
                _glimwell_uj_emit_kept "$path" "${code:-failed}" "a step after the app's removal failed"
            else
                _glimwell_uj_emit_kept "$path" "${code:-failed}" "the app was not removed"
            fi
            leftovers_kept=1
        else
            _glimwell_uj_emit_removed "$path" ""
        fi
    done
    local q_app status="removed" q_reason="null"
    glimwell_json_quote q_app "$listed"
    if [[ "$bundle_gone" != true ]]; then
        status="kept"
        q_reason="\"${code:-failed}\""
        _GLIMWELL_UJ_N_APPS_KEPT=$((_GLIMWELL_UJ_N_APPS_KEPT + 1))
    else
        _GLIMWELL_UJ_N_APPS=$((_GLIMWELL_UJ_N_APPS + 1))
        if [[ $leftovers_kept -ne 0 || -n "$failed_reason" ]]; then
            status="partial"
            [[ -z "$failed_reason" ]] || q_reason="\"${code:-failed}\""
        fi
    fi
    glimwell_uninstall_json_emit "{\"type\":\"app_done\",\"app\":$q_app,\"status\":\"$status\",\"reason\":$q_reason}"
}

_glimwell_uj_emit_app_start() {
    local listed="$1" name="$2" q_app q_name
    glimwell_json_quote q_app "$listed"
    glimwell_json_quote q_name "$name"
    glimwell_uninstall_json_emit "{\"type\":\"app_start\",\"app\":$q_app,\"name\":$q_name}"
}

glimwell_uninstall_json_run() {
    local -a _gw_status=() _gw_note=() _gw_row=() _gw_detail=()
    local -a running_apps=() sudo_apps=() brew_cask_apps=() blocked_apps=()
    local -a manual_removal_apps=() leftover_notes=() app_details=()
    local total_estimated_size=0 _batch_scan_stage="application inspection" _batch_scan_app_name=""
    local rc=0
    _glimwell_uj_classify_and_scan || rc=$?
    if [[ $rc -ne 0 ]]; then
        mole_rc_signal "$rc" && return "$rc"
        return 1
    fi

    # What _batch_execute_removals writes, kept across apps: a later app's
    # sibling recheck must know which apps this run already removed.
    local success_count=0 failed_count=0 brew_apps_removed=0 total_size_freed=0
    local -a failed_items=() success_items=() success_names=() success_dock_targets=()
    local -a system_extension_warning_apps=() review_only_system_leftovers=()
    local -a review_only_system_leftover_keys=() running_at_uninstall_apps=()
    local _batch_exec_app_name="" _batch_exec_stage=""
    # As the terminal sets it once the user confirms.
    export MOLE_UNINSTALL_MODE=1

    local -a all_detail_paths=()
    local i=0 listed path
    for listed in "${_GLIMWELL_UJ_SEL_APPS[@]}"; do
        if [[ "${_gw_status[i]}" == "ok" ]]; then
            while IFS= read -r path; do
                [[ -n "$path" ]] && all_detail_paths+=("$path")
            done < <(_glimwell_uj_detail_leftovers "${_gw_detail[i]}")
        fi
        i=$((i + 1))
    done

    local status detail name app_path bundle_id total_kb encoded_files rest exec_rc
    # A leftover two listed apps share goes with the first of them only.
    local -a chosen=() claimed=()
    i=0
    for listed in "${_GLIMWELL_UJ_SEL_APPS[@]}"; do
        [[ $_GLIMWELL_UJ_CANCEL -eq 0 ]] || break
        status="${_gw_status[i]}"
        detail="${_gw_detail[i]:-}"
        name=""
        if [[ -n "$detail" ]]; then
            name="${detail%%|*}"
        elif [[ -n "${_gw_row[i]}" ]]; then
            IFS='|' read -r _ _ name _ <<< "${_gw_row[i]}"
        fi
        if [[ -z "$name" ]]; then
            name="${listed##*/}"
            name="${name%.[aA][pP][pP]}"
        fi
        _GLIMWELL_UJ_APP="$listed"
        _GLIMWELL_UJ_REPORTED=()
        _GLIMWELL_UJ_REASON_CODE=""
        _GLIMWELL_UJ_LAST_REASON=""
        _GLIMWELL_UJ_BREW_NEEDS_ADMIN=0
        _GLIMWELL_UJ_APP_ATTEMPTED=0
        _glimwell_uj_emit_app_start "$listed" "$name"

        chosen=()
        if [[ "$status" == "ok" ]]; then
            while IFS= read -r path; do
                [[ -n "$path" ]] || continue
                _glimwell_uj_in_list "$path" "${claimed[@]+"${claimed[@]}"}" && continue
                if _glimwell_uj_in_list "$path" "${_GLIMWELL_UJ_SEL_PATHS[@]+"${_GLIMWELL_UJ_SEL_PATHS[@]}"}"; then
                    chosen+=("$path")
                    claimed+=("$path")
                fi
            done < <(_glimwell_uj_detail_leftovers "$detail")
        fi

        if [[ "$status" != "ok" ]]; then
            case "$status" in
                missing) _GLIMWELL_UJ_REASON_CODE="not_found" ;;
                manual) _GLIMWELL_UJ_REASON_CODE="failed" ;;
                *) _GLIMWELL_UJ_REASON_CODE="protected" ;;
            esac
            if [[ "$status" == "missing" ]]; then
                local q_app=""
                glimwell_json_quote q_app "$listed"
                glimwell_uninstall_json_emit "{\"type\":\"kept\",\"app\":$q_app,\"path\":$q_app,\"reason\":\"not_found\",\"detail\":\"No app is at this path.\"}"
                _GLIMWELL_UJ_N_KEPT=$((_GLIMWELL_UJ_N_KEPT + 1))
                _GLIMWELL_UJ_REPORTED+=("$listed")
                _GLIMWELL_UJ_N_APPS_KEPT=$((_GLIMWELL_UJ_N_APPS_KEPT + 1))
                glimwell_uninstall_json_emit "{\"type\":\"app_done\",\"app\":$q_app,\"status\":\"kept\",\"reason\":\"not_found\"}"
            else
                _glimwell_uj_finish_app "$listed" "${_gw_note[i]}"
            fi
            _GLIMWELL_UJ_APP=""
            i=$((i + 1))
            continue
        fi

        # Rebuild the scanned plan with only the chosen leftovers.
        local d_sudo=""
        IFS='|' read -r name app_path bundle_id total_kb encoded_files rest <<< "$detail"
        IFS='|' read -r _ _ _ _ _ _ _ d_sudo _ <<< "$detail"
        local chosen_text="" encoded_chosen=""
        if [[ ${#chosen[@]} -gt 0 ]]; then
            chosen_text=$(printf '%s\n' "${chosen[@]}")
            encoded_chosen=$(printf '%s' "$chosen_text" | base64 | tr -d '\n') || encoded_chosen=""
        fi
        app_details=("$name|$app_path|$bundle_id|$total_kb|$encoded_chosen|$rest")

        _GLIMWELL_UJ_ALLOW=("$listed" "${chosen[@]+"${chosen[@]}"}")
        _GLIMWELL_UJ_ALLOW_ACTIVE=1
        local failed_before=$failed_count
        exec_rc=0
        if [[ "$d_sudo" == "true" ]]; then
            _GLIMWELL_UJ_REASON_CODE="needs_admin"
            _GLIMWELL_UJ_LAST_REASON="removing it needs an administrator password"
            failed_count=$((failed_count + 1))
        else
            _GLIMWELL_UJ_APP_ATTEMPTED=1
            _batch_execute_removals > /dev/null || exec_rc=$?
        fi
        _GLIMWELL_UJ_ALLOW_ACTIVE=0
        _GLIMWELL_UJ_ALLOW=()

        local failed_reason=""
        if [[ $exec_rc -ne 0 ]]; then
            if mole_rc_signal "$exec_rc"; then
                [[ $_GLIMWELL_UJ_CANCEL -ne 0 ]] || _GLIMWELL_UJ_CANCEL=$exec_rc
                failed_reason="cancelled"
                _GLIMWELL_UJ_REASON_CODE="failed"
            elif mole_rc_timeout "$exec_rc"; then
                failed_reason="${_batch_exec_stage:-a step} timed out"
                _glimwell_uj_error "Uninstall of $name stopped: $failed_reason."
            else
                failed_reason="${_batch_exec_stage:-a step} failed (exit $exec_rc)"
                _glimwell_uj_error "Uninstall of $name stopped during $failed_reason."
            fi
        elif [[ $failed_count -gt $failed_before ]]; then
            failed_reason="${_GLIMWELL_UJ_LAST_REASON:-removal failed}"
        fi
        _glimwell_uj_finish_app "$listed" "$failed_reason" "${chosen[@]+"${chosen[@]}"}"
        _GLIMWELL_UJ_APP=""
        i=$((i + 1))
    done

    # Listed leftovers that no listed app's fresh scan found stay.
    if [[ $_GLIMWELL_UJ_CANCEL -eq 0 ]]; then
        _GLIMWELL_UJ_REPORTED=()
        for path in "${_GLIMWELL_UJ_SEL_PATHS[@]+"${_GLIMWELL_UJ_SEL_PATHS[@]}"}"; do
            _glimwell_uj_in_list "$path" "${all_detail_paths[@]+"${all_detail_paths[@]}"}" && continue
            _glimwell_uj_emit_kept "$path" "not_found" "this run's scan of the listed apps did not find it"
        done
    fi

    # As the terminal does after a batch: drop the apps' Dock tiles and
    # refresh LaunchServices, in the background, off the event stream.
    if [[ ${#success_dock_targets[@]} -gt 0 ]]; then
        (
            remove_apps_from_dock "${success_dock_targets[@]}" > /dev/null 2>&1 || true
            refresh_launch_services_after_uninstall > /dev/null 2>&1 || true
        ) > /dev/null 2>&1 < /dev/null 8>&- &
        disown $! 2> /dev/null || true
    fi
    unset MOLE_UNINSTALL_MODE
    total_size_cleaned=$((${total_size_cleaned:-0} + total_size_freed))
    [[ $_GLIMWELL_UJ_CANCEL -eq 0 ]] || return "$_GLIMWELL_UJ_CANCEL"
    return 0
}

# Entry from bin/uninstall.sh main once flags are parsed.
# Usage: glimwell_uninstall_json_main LIST JSON ONLY_SET ONLY_FILE PERMANENT WITH_DATA [NAME...]
glimwell_uninstall_json_main() {
    local list_mode="$1" json="$2" only_set="$3" only_file="$4" permanent="$5" with_data="$6"
    shift 6
    if [[ "$json" != "1" ]]; then
        _glimwell_uj_refuse "--only works only with --json."
        return 1
    fi
    if [[ $# -gt 0 ]]; then
        _glimwell_uj_refuse "--json takes no app names; list the apps in the --only file."
        return 1
    fi
    if [[ "$permanent" == "1" || "$with_data" == "1" ]]; then
        _glimwell_uj_refuse "--json refuses --permanent and --with-data: everything goes to the Trash, and the --only file chooses data item by item."
        return 1
    fi
    if [[ "$list_mode" == "1" ]]; then
        if [[ "$only_set" == "1" ]]; then
            _glimwell_uj_refuse "--list takes no --only file."
            return 1
        fi
        glimwell_uninstall_json_list
        return $?
    fi
    if [[ "$only_set" != "1" ]]; then
        _glimwell_uj_refuse "--json needs --only FILE (or --list); a call that lost its list never uninstalls by name."
        return 1
    fi

    local dry=0
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && dry=1
    glimwell_uninstall_selection_load "$only_file" "$dry" || return 1

    export MOLE_DELETE_MODE="trash"
    MOLE_UNINSTALL_WITH_DATA=0
    _GLIMWELL_UJ_DRY=$dry
    log_operation_session_start "uninstall"

    exec 8>&1
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        exec 1>&2
    else
        exec 1> /dev/null
    fi
    GLIMWELL_UNINSTALL_JSON=1
    local dry_json="false"
    [[ $dry -eq 1 ]] && dry_json="true"
    glimwell_uninstall_json_emit "{\"type\":\"start\",\"version\":1,\"dry_run\":$dry_json}"

    # Cancel at the next app boundary: the item in hand finishes first.
    trap '_GLIMWELL_UJ_CANCEL=130' INT
    trap '_GLIMWELL_UJ_CANCEL=143' TERM

    local rc=0
    if [[ $dry -eq 1 ]]; then
        glimwell_uninstall_json_preview || rc=$?
    else
        glimwell_uninstall_json_run || rc=$?
    fi
    [[ $_GLIMWELL_UJ_CANCEL -eq 0 ]] || rc=$_GLIMWELL_UJ_CANCEL
    trap 'cleanup 130' INT
    trap 'cleanup 143' TERM

    if [[ $rc -eq 130 || $rc -eq 143 ]]; then
        _glimwell_uj_summary cancelled "$rc"
        return "$rc"
    elif [[ $rc -ne 0 ]]; then
        _glimwell_uj_summary failed 1
        return 1
    fi
    local exit_code=0
    [[ $_GLIMWELL_UJ_N_APPS_KEPT -eq 0 ]] || exit_code=1
    _glimwell_uj_summary complete "$exit_code"
    return "$exit_code"
}
