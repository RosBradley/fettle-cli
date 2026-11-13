#!/bin/bash
# Glimwell: the machine interface the Glimwell Mac app uses for Clean.
#
#   glimwell clean --dry-run --json          preview as one JSON object per line
#   glimwell clean --json --only FILE        remove only what FILE lists
#
# FILE holds one ID per line, as the preview printed them: "path:<absolute
# path>" for a file or folder, "step:<name>" for a step that runs another
# tool (brew cleanup, go clean, docker prune...). While MOLE_CLEAN_ONLY_FILE
# names that file, the run removes a path only when it is listed or inside a
# listed folder, and runs a tool step only when its step ID is listed. Every
# other check of a normal run still applies. Selection only ever narrows what
# a run removes, so a stray value can only keep files; it never widens a run.
#
# Where the selection is enforced, each place marked "glimwell:":
#   validate_path_for_deletion (file_ops.sh)  the funnel every safe_* sink and
#                                             mole_delete pass: refuses unselected
#   _safe_clean_impl (bin/clean.sh), safe_find_delete (file_ops.sh), the Trash
#                                             pass over unselected items early
#   Time Machine and container stubs          delete outside the funnel; check here
#   tool steps (clean_tool_cache, brew, go, gh, docker, tart, simulators,
#   automation browsers)                      glimwell_clean_step_selected
# A tool step calls glimwell_clean_step_selected before any check of its own
# and then declares `local _MOLE_SELECTED_STEP=1`, so its own path probes and
# deletions are not refused as unselected: the user selected the step.
# log_operation (log.sh) and mole_review_row (base.sh) report events.

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

_GLIMWELL_SELECTION_FILE=""   # the file the tables below were built from
_GLIMWELL_SELECTION_OK=false
# Selected paths whose text cannot become a variable name; checked by exact
# comparison. Newline-delimited.
_GLIMWELL_SELECTION_RAW_PATHS=""
# Only a file named by --only builds a selection. A step scope or a table entry
# inherited from the environment would widen the run, so none survives loading.
unset _MOLE_SELECTED_STEP
for _glimwell_inherited in ${!_GLIMWELL_SEL_@}; do
    unset "$_glimwell_inherited"
done
unset _glimwell_inherited

# Strip trailing slashes and collapse doubled ones, as is_path_whitelisted
# does, so "a//b/" and "a/b" are one path. Sets _GLIMWELL_SELECTION_NORM.
_glimwell_selection_normalize() {
    local value="$1"
    local single="/" double="//"
    while [[ "$value" == *"$double"* ]]; do
        value="${value//$double/$single}"
    done
    while [[ ${#value} -gt 1 && "$value" == */ ]]; do
        value="${value%/}"
    done
    _GLIMWELL_SELECTION_NORM="$value"
}

# Turn a path or step name into a variable-name suffix, one to one: "_" and
# every other allowed character become "_" plus two hex digits. Text with any
# character outside the table cannot be keyed (returns 1) and is compared
# exactly instead, so two different paths never share a key.
_GLIMWELL_KEY_CHARS=("/" "." "-" " " "+" "@" "," ":" "~" "(" ")" "'" "&" "#" "=" "%" "!" "[" "]" "{" "}")
_GLIMWELL_KEY_CODES=(_2f _2e _2d _20 _2b _40 _2c _3a _7e _28 _29 _27 _26 _23 _3d _25 _21 _5b _5d _7b _7d)
_glimwell_selection_key() {
    local k="$1" i=0
    case "$k" in
        "") return 1 ;;
    esac
    k="${k//_/_5f}"
    while [[ $i -lt ${#_GLIMWELL_KEY_CHARS[@]} ]]; do
        # Quoted, so each character matches only itself.
        k="${k//"${_GLIMWELL_KEY_CHARS[$i]}"/${_GLIMWELL_KEY_CODES[$i]}}"
        i=$((i + 1))
    done
    case "$k" in
        *[!A-Za-z0-9_]*) return 1 ;;
    esac
    _GLIMWELL_SELECTION_KEY="$k"
}

_glimwell_selection_mark() {
    local prefix="$1" value="$2"
    if _glimwell_selection_key "$value"; then
        printf -v "${prefix}${_GLIMWELL_SELECTION_KEY}" '%s' 1
        return 0
    fi
    return 1
}

_glimwell_selection_add_path() {
    _glimwell_selection_normalize "$1"
    local path="$_GLIMWELL_SELECTION_NORM"
    [[ "$path" == /?*/?* ]] || return 1
    if ! _glimwell_selection_mark _GLIMWELL_SEL_P_ "$path"; then
        _GLIMWELL_SELECTION_RAW_PATHS+=$'\n'"$path"
    fi
}

# Check a selection file. On a problem, print it to stderr and return 1.
glimwell_clean_selection_check_file() {
    local file="$1"
    if [[ -z "$file" || ! -e "$file" ]]; then
        printf 'glimwell clean --only: the selection file was not found: %s\n' "$file" >&2
        return 1
    fi
    if [[ -L "$file" || ! -f "$file" || ! -r "$file" ]]; then
        printf 'glimwell clean --only: the selection must be a readable regular file, not a link or folder: %s\n' "$file" >&2
        return 1
    fi
    local line="" number=0 count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        number=$((number + 1))
        case "$line" in
            "") continue ;;
            path:/*)
                local dotdot_pattern='(^path:|/)\.\.(/|$)'
                _glimwell_selection_normalize "${line#path:}"
                if [[ "$line" =~ [[:cntrl:]] || "$line" =~ $dotdot_pattern || "$_GLIMWELL_SELECTION_NORM" != /?*/?* ]]; then
                    printf 'glimwell clean --only: line %d is not a plain absolute path below a top-level folder.\n' "$number" >&2
                    return 1
                fi
                ;;
            step:?*)
                if [[ "$line" == *[!A-Za-z0-9:-]* ]]; then
                    printf 'glimwell clean --only: line %d is not a step ID the preview printed.\n' "$number" >&2
                    return 1
                fi
                ;;
            *)
                printf 'glimwell clean --only: line %d is neither "path:/..." nor "step:...". Use the IDs from glimwell clean --dry-run --json.\n' "$number" >&2
                return 1
                ;;
        esac
        count=$((count + 1))
    done < "$file"
    if [[ $count -eq 0 ]]; then
        printf 'glimwell clean --only: the selection file lists nothing to remove.\n' >&2
        return 1
    fi
    return 0
}

# Build the lookup tables once per process. Returns 1 when the file cannot be
# read whole; callers then refuse every path and step.
_glimwell_selection_load() {
    local file="${MOLE_CLEAN_ONLY_FILE:-}"
    [[ -n "$file" ]] || return 1
    if [[ "$_GLIMWELL_SELECTION_FILE" == "$file" ]]; then
        [[ "$_GLIMWELL_SELECTION_OK" == "true" ]]
        return
    fi
    _GLIMWELL_SELECTION_FILE="$file"
    _GLIMWELL_SELECTION_OK=false
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    local line=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "") ;;
            path:/*) _glimwell_selection_add_path "${line#path:}" || return 1 ;;
            step:?*) _glimwell_selection_mark _GLIMWELL_SEL_S_ "${line#step:}" || return 1 ;;
            *) return 1 ;;
        esac
    done < "$file"
    _GLIMWELL_SELECTION_OK=true
}

# 0 when a selection limits this part of the run: --only is active and the
# caller is not inside a tool step the user selected.
glimwell_clean_selection_restricts() {
    [[ -n "${MOLE_CLEAN_ONLY_FILE:-}" && "${MOLE_CURRENT_COMMAND:-}" == "clean" &&
        "${_MOLE_SELECTED_STEP:-}" != "1" ]]
}

# 0 when PATH was selected or lies inside a selected folder.
glimwell_clean_selection_allows_path() {
    _glimwell_selection_load || return 1
    _glimwell_selection_normalize "$1"
    local path="$_GLIMWELL_SELECTION_NORM" name=""
    [[ "$path" == /* ]] || return 1
    # "<selected>/../other" is text inside a selected folder, not a path in it.
    local dotdot_pattern='(^|/)\.\.(/|$)'
    [[ ! "$path" =~ $dotdot_pattern ]] || return 1
    local probe="$path"
    while [[ -n "$probe" ]]; do
        if _glimwell_selection_key "$probe"; then
            name="_GLIMWELL_SEL_P_$_GLIMWELL_SELECTION_KEY"
            [[ -n "${!name:-}" ]] && return 0
        fi
        [[ "$probe" == */* ]] || break
        probe="${probe%/*}"
    done
    # Walk the list in place: a here-string needs a temp file on bash 3.2.
    local rest="$_GLIMWELL_SELECTION_RAW_PATHS" raw=""
    while [[ -n "$rest" ]]; do
        rest="${rest#$'\n'}"
        raw="${rest%%$'\n'*}"
        if [[ "$rest" == *$'\n'* ]]; then
            rest="${rest#*$'\n'}"
            rest=$'\n'"$rest"
        else
            rest=""
        fi
        [[ -n "$raw" ]] || continue
        [[ "$path" == "$raw" || "$path" == "$raw"/* ]] && return 0
    done
    return 1
}

# For the deletion funnel and the early skips: 0 when PATH must not be removed.
glimwell_clean_selection_refuses_path() {
    glimwell_clean_selection_restricts || return 1
    ! glimwell_clean_selection_allows_path "$1"
}

# The step ID for a row label and the folder it works on, into the variable
# named by $3: "npm cache" + "/Users/me/.npm" -> "step:npm-cache-1234567890".
# The folder's checksum keeps two runs of one tool apart (pnpm has one store
# per installation), so selecting one never selects the other.
glimwell_clean_step_id() {
    local label="$1" path="${2:-}" sum=""
    label="${label//[!A-Za-z0-9]/-}"
    if [[ -n "$path" ]]; then
        sum=$(printf '%s' "$path" | /usr/bin/cksum 2> /dev/null) || sum=""
        sum="${sum%% *}"
        [[ "$sum" =~ ^[0-9]+$ ]] || sum="unknown"
        label+="-$sum"
    fi
    printf -v "${3:-_GLIMWELL_STEP_ID}" 'step:%s' "$label"
}

# A tool step calls this first, with its row label and the folder it works on
# (the same two the preview gave). Returns 1 when --only is active and the
# user did not select the step; the step then returns without doing anything.
glimwell_clean_step_selected() {
    [[ -n "${MOLE_CLEAN_ONLY_FILE:-}" && "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] || return 0
    local id=""
    glimwell_clean_step_id "$1" "${2:-}" id
    _glimwell_selection_load || return 1
    _glimwell_selection_key "${id#step:}" || return 1
    local name="_GLIMWELL_SEL_S_$_GLIMWELL_SELECTION_KEY"
    if [[ -n "${!name:-}" ]]; then
        return 0
    fi
    debug_log "Not selected for this run: $1"
    return 1
}

# ---------------------------------------------------------------------------
# JSON events (fd 8 while GLIMWELL_CLEAN_JSON=1; bin/clean.sh opens it)
# ---------------------------------------------------------------------------

GLIMWELL_CLEAN_JSON=0
_GLIMWELL_EMITTED_STEPS=""

glimwell_clean_json_active() {
    [[ "$GLIMWELL_CLEAN_JSON" == "1" ]]
}

# Store VALUE as a JSON string literal in the variable named by $1. Printable
# ASCII is escaped in the shell; anything else goes through Perl, which also
# replaces bytes that are not valid UTF-8 with U+FFFD.
glimwell_json_quote() {
    local __out="$1" __value="${2-}"
    local LC_ALL=C
    if [[ "$__value" != *[![:print:]]* ]]; then
        __value="${__value//\\/\\\\}"
        __value="${__value//\"/\\\"}"
        printf -v "$__out" '"%s"' "$__value"
        return 0
    fi
    local __quoted=""
    # shellcheck disable=SC2016  # Perl code, not shell expansion.
    __quoted=$(printf '%s' "$__value" | /usr/bin/perl -MEncode -e '
        local $/; my $s = <STDIN>; $s = "" unless defined $s;
        $s = Encode::decode("UTF-8", $s, Encode::FB_DEFAULT);
        $s =~ s/(["\\])/\\$1/g;
        $s =~ s/([\x00-\x1f\x7f])/sprintf("\\u%04x", ord($1))/ge;
        print "\"", Encode::encode("UTF-8", $s), "\"";
    ' 2> /dev/null) || __quoted='"�"'
    printf -v "$__out" '%s' "$__quoted"
}

glimwell_clean_json_emit() {
    glimwell_clean_json_active || return 0
    printf '%s\n' "$1" 2> /dev/null >&8 || true
}

# A JSON number, or null when VALUE is not a whole number.
_glimwell_json_number() {
    if [[ "${2-}" =~ ^[0-9]+$ ]]; then
        printf -v "$1" '%s' "$2"
    else
        printf -v "$1" '%s' null
    fi
}

glimwell_clean_json_start() {
    local dry="false"
    [[ "${DRY_RUN:-false}" == "true" ]] && dry="true"
    glimwell_clean_json_emit "{\"type\":\"start\",\"version\":1,\"dry_run\":$dry,\"admin\":false}"
}

glimwell_clean_json_section() {
    glimwell_clean_json_active || return 0
    local name=""
    glimwell_json_quote name "$1"
    glimwell_clean_json_emit "{\"type\":\"section\",\"name\":$name}"
}

glimwell_clean_json_error() {
    glimwell_clean_json_active || return 0
    local message=""
    glimwell_json_quote message "$1"
    glimwell_clean_json_emit "{\"type\":\"error\",\"message\":$message}"
}

# A preview item for a tool step: LABEL [PATH] [SIZE_KB]. Printed once per ID.
glimwell_clean_step_preview() {
    glimwell_clean_json_active || return 0
    [[ "${DRY_RUN:-false}" == "true" ]] || return 0
    local label="$1" path="${2:-}" size_kb="${3:-}"
    local id="" bytes=""
    glimwell_clean_step_id "$label" "$path" id
    [[ "$_GLIMWELL_EMITTED_STEPS" == *$'\n'"$id"$'\n'* ]] && return 0
    _GLIMWELL_EMITTED_STEPS+=$'\n'"$id"$'\n'
    [[ "$size_kb" =~ ^[0-9]+$ ]] && size_kb=$((size_kb * 1024))
    _glimwell_json_number bytes "$size_kb"
    local q_id="" q_section="" q_label="" q_path="null"
    glimwell_json_quote q_id "$id"
    glimwell_json_quote q_section "${CURRENT_SECTION:-}"
    glimwell_json_quote q_label "$label"
    # A folder name holding a control character is shown as no folder; the ID
    # stays a plain checksum either way.
    local cntrl_pattern='[[:cntrl:]]'
    [[ -z "$path" || "$path" =~ $cntrl_pattern ]] || glimwell_json_quote q_path "$path"
    glimwell_clean_json_emit "{\"type\":\"item\",\"id\":$q_id,\"kind\":\"step\",\"section\":$q_section,\"label\":$q_label,\"path\":$q_path,\"bytes\":$bytes,\"files\":null,\"covered_by\":null}"
}

glimwell_clean_json_review() {
    glimwell_clean_json_active || return 0
    local q_section="" q_label="" q_path="null" q_value="null" q_fact="null"
    glimwell_json_quote q_section "${CURRENT_SECTION:-}"
    glimwell_json_quote q_label "$1"
    [[ -z "${2:-}" ]] || glimwell_json_quote q_path "$2"
    [[ -z "${3:-}" ]] || glimwell_json_quote q_value "$3"
    [[ -z "${4:-}" ]] || glimwell_json_quote q_fact "$4"
    glimwell_clean_json_emit "{\"type\":\"review\",\"section\":$q_section,\"label\":$q_label,\"path\":$q_path,\"value\":$q_value,\"fact\":$q_fact}"
}

glimwell_clean_json_held() {
    glimwell_clean_json_active || return 0
    local q_name=""
    glimwell_json_quote q_name "$1"
    glimwell_clean_json_emit "{\"type\":\"held\",\"name\":$q_name,\"reason\":\"running\"}"
}

# Mirror an operations.log row of a real run as a "removed" or "kept" event.
glimwell_clean_json_operation() {
    glimwell_clean_json_active || return 0
    [[ "${DRY_RUN:-false}" != "true" ]] || return 0
    local action="$1" path="$2" detail="${3:-}"
    [[ -n "$path" ]] || return 0
    local q_path="" q_detail="null" reason=""
    case "$action" in
        REMOVED)
            glimwell_json_quote q_path "$path"
            [[ -z "$detail" ]] || glimwell_json_quote q_detail "$detail"
            glimwell_clean_json_emit "{\"type\":\"removed\",\"path\":$q_path,\"detail\":$q_detail}"
            return 0
            ;;
        SKIPPED | FAILED) ;;
        *) return 0 ;;
    esac
    case "$detail" in
        "not selected") return 0 ;;
        whitelist) reason="whitelist" ;;
        "live user cache" | "active or unknown SQLite database" | "active or unknown download") reason="in_use" ;;
        "identity changed") reason="changed" ;;
        "section time limit reached" | "removal timed out") reason="timeout" ;;
        *)
            if [[ "$action" == "FAILED" ]]; then
                reason="failed"
            else
                reason="protected"
            fi
            ;;
    esac
    glimwell_json_quote q_path "$path"
    [[ -z "$detail" ]] || glimwell_json_quote q_detail "$detail"
    glimwell_clean_json_emit "{\"type\":\"kept\",\"path\":$q_path,\"reason\":\"$reason\",\"detail\":$q_detail}"
}

# Turn the deduplicated preview ledger (NUL-separated: identity, size KB,
# files, size known, section, path, covering ancestor) into "item" events.
# LABEL_FILE holds NUL-separated identity and row-label pairs.
glimwell_clean_json_items_from_ledger() {
    local ledger="$1" label_file="${2:-}"
    glimwell_clean_json_active || return 0
    [[ -f "$ledger" ]] || return 0
    # shellcheck disable=SC2016  # Perl code, not shell expansion.
    /usr/bin/perl -MEncode -e '
        use strict; use warnings;
        my ($ledger, $label_file) = @ARGV;
        sub jstr {
            my $s = shift;
            return "null" unless defined $s;
            $s = Encode::decode("UTF-8", $s, Encode::FB_DEFAULT);
            $s =~ s/(["\\])/\\$1/g;
            $s =~ s/([\x00-\x1f\x7f])/sprintf("\\u%04x", ord($1))/ge;
            return "\"" . Encode::encode("UTF-8", $s) . "\"";
        }
        sub trim { my $p = shift; $p =~ s{/+\z}{} if length($p) > 1; return $p; }
        local $/ = "\0";
        my %label;
        if (defined $label_file && length $label_file && open(my $lf, "<", $label_file)) {
            binmode $lf;
            while (defined(my $id = <$lf>)) {
                my $l = <$lf>; last unless defined $l;
                chomp $id; chomp $l;
                $label{$id} = $l unless exists $label{$id};
            }
            close $lf;
        }
        open(my $in, "<", $ledger) or exit 0;
        binmode $in; binmode STDOUT;
        while (defined(my $identity = <$in>)) {
            my @f;
            for (1 .. 6) { my $v = <$in>; last unless defined $v; chomp $v; push @f, $v; }
            last unless @f == 6;
            chomp $identity;
            my ($kb, $files, $known, $section, $path, $covered) = @f;
            # A path with a control character can never be removed (the
            # deletion funnel refuses it), and its ID would not survive being
            # written as one line of a selection file. Offer nothing for it.
            next if $path =~ /[\x00-\x1f\x7f]/;
            $covered = "" if $covered =~ /[\x00-\x1f\x7f]/;
            $path = trim($path);
            my $bytes = ($known eq "true" && $kb =~ /\A[0-9]+\z/) ? $kb * 1024 : "null";
            $files = 1 unless $files =~ /\A[0-9]+\z/ && $files > 0;
            my $cov = length($covered) ? jstr("path:" . trim($covered)) : "null";
            print "{\"type\":\"item\",\"id\":", jstr("path:" . $path),
                ",\"kind\":\"path\",\"section\":", jstr($section),
                ",\"label\":", jstr($label{$identity}),
                ",\"path\":", jstr($path),
                ",\"bytes\":", $bytes,
                ",\"files\":", $files,
                ",\"covered_by\":", $cov, "}\n";
        }
    ' "$ledger" "$label_file" >&8 2> /dev/null || true
}

# The last event of every run.
glimwell_clean_json_summary() {
    glimwell_clean_json_active || return 0
    local status="$1" exit_code="$2" size_kb="$3" items="$4" partial="$5"
    local dry="false" bytes="" count=""
    [[ "${DRY_RUN:-false}" == "true" ]] && dry="true"
    [[ "$partial" == "true" ]] || partial="false"
    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
    _glimwell_json_number bytes "$((size_kb * 1024))"
    _glimwell_json_number count "$items"
    [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code=1
    glimwell_clean_json_emit "{\"type\":\"summary\",\"dry_run\":$dry,\"status\":\"$status\",\"exit\":$exit_code,\"bytes\":$bytes,\"items\":$count,\"partial\":$partial,\"admin_skipped\":true}"
}
