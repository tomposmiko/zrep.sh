#!/bin/bash
# shellcheck disable=SC1091
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/_zrep_common.sh"

while (($#)); do
    case "$1" in
        -c|--conf|--conffile|-f|--freq)
            (($# >= 2)) || fc_say_fail "Missing argument for '$1'"
            fc_check_arg "$2" "$1"
            case "$1" in
                -f|--freq) FREQ="$2" ;;
                *) FILE_CONFIG="$2" ;;
            esac
            shift 2 ;;
        *) fc_say_fail "Usage: $0 [-c FILE] [-f hourly|daily|weekly|monthly]" ;;
    esac
done
f_validate_freq
f_read_sources
status=0
fc_say_info "BEGIN: $(date '+%Y-%m-%d %H:%M')"
for source_line in "${SOURCES[@]}"; do
    fc_say_info "$source_line"
    # A separate child prevents errexit from being disabled inside the job.
    if ! "$SCRIPT_DIR/zrep.sh" --quiet -s "$source_line" -f "$FREQ" -c "$FILE_CONFIG" </dev/null; then
        printf 'Replication failed: %s\n' "$source_line" >&2
        status=1
    fi
done
fc_say_info "FINISH: $(date '+%Y-%m-%d %H:%M')"
exit "$status"
