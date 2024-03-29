#!/bin/bash
# shellcheck disable=SC1091

set -e

. "$(dirname "$(readlink /proc/$$/fd/255 2>/dev/null)")/_common.sh"

. "$(dirname "$(readlink /proc/$$/fd/255 2>/dev/null)")/_zrep_common.sh"

f_process_args() {
    # Exit if no arguments!
    (( "$#" )) || f_usage

    while [ "$#" -gt "0" ]; do
        case "$1" in
            -c|--conf)
                PARAM=$2
                fc_check_arg "$PARAM" "config file"
                FILE_CONFIG="$PARAM"
                shift 2
            ;;

            -f|--freq)
                PARAM=$2
                fc_check_arg "$PARAM" "frequency"
                FREQ="$PARAM"
                shift 2
            ;;

            *)
                f_usage
            ;;
        esac
    done
}

f_run_all() {
    fc_say_info "BEGIN: $(date "+%Y-%m-%d %H:%M")"

    local source_line
    local IFS=$'\n'

    # shellcheck disable=SC2013
    for source_line in $(grep -v "^#" "$FILE_CONFIG"); do
        DATE=$(date "+%Y-%m-%d %H:%M:%S")
        fc_say_info "${DATE} - $source_line"
        zrep.sh --quiet -s "$source_line" -f "$FREQ" -c "$FILE_CONFIG" || true
    done

    fc_say_info "FINISH: $(date "+%Y-%m-%d %H:%M")"
}

f_usage(){
    echo "Usage:"
    echo "  $0 [-c conffile]"
    echo
    echo "      -c|--conffile     <config file>"
    echo "      -f|--freq         <frequency>"
    echo

    exit 1
}

f_process_args "${@}"
f_validate_config_path
f_validate_freq
f_run_all
