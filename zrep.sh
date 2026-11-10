#!/bin/bash
# shellcheck disable=SC1091
# Resolve installed symlinks before finding the adjacent helpers and child job.
# Enable strict mode before loading helpers so a missing file cannot run a job.
set -euo pipefail
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")
. "$SCRIPT_DIR/_zrep_common.sh"

HOST_IN_PATH=0
LIST_SNAPSHOTS=false
PARAM_SOURCE=""
QUIET=false
DEBUG=false
SOURCE_SET=false

f_usage() {
    echo "Usage: $0 (-s|--source SOURCE | -l|--list SOURCE) [-c|--conf FILE]"
    echo "       [-f|--freq hourly|daily|weekly|monthly] [-b|--bwlimit LIMIT]"
    echo "       [-E|--extended-vault] [-q|--quiet | --debug]"
    exit 1
}

while (($#)); do
    case "$1" in
        -c|--conf|-s|--source|-l|--list|-f|--freq|-b|--bwlimit)
            (($# >= 2)) || fc_say_fail "Missing argument for '$1'"
            fc_check_arg "$2" "$1"
            case "$1" in
                -c|--conf) FILE_CONFIG="$2" ;;
                -f|--freq) FREQ="$2" ;;
                -b|--bwlimit) ARGS_SYNCOID+=("--target-bwlimit=$2") ;;
                *)
                    [[ "$SOURCE_SET" == false ]] || fc_say_fail "Specify exactly one source or list option"
                    SOURCE_SET=true
                    PARAM_SOURCE="$2"
                    [[ "$1" != -l && "$1" != --list ]] || LIST_SNAPSHOTS=true
                    ;;
            esac
            shift 2 ;;
        -E|--extended-vault) HOST_IN_PATH=1; shift ;;
        -q|--quiet) QUIET=true; ARGS_SYNCOID+=(--quiet); shift ;;
        --debug) DEBUG=true; ARGS_SYNCOID+=(--debug); shift ;;
        *) f_usage ;;
    esac
done
[[ "$SOURCE_SET" == true ]] || f_usage
[[ "$QUIET" == false || "$DEBUG" == false ]] || fc_say_fail "Quiet and debug are mutually exclusive"
f_validate_freq
f_read_sources

matches=()
for source_line in "${SOURCES[@]}"; do
    IFS=: read -r _ guest _ <<< "$source_line"
    if [[ "$PARAM_SOURCE" == "$source_line" || "$PARAM_SOURCE" == "$guest" ]]; then
        matches+=("$source_line")
    fi
done
((${#matches[@]} == 1)) || fc_say_fail "Exactly one source must match '$PARAM_SOURCE'; found ${#matches[@]}"
IFS=: read -r SOURCE_HOST VM_NAME VIRT_TYPE <<< "${matches[0]}"
[[ "$(zfs get type -H -o value "$DATASET_ZREP")" == filesystem ]] || fc_say_fail "Missing root dataset: '$DATASET_ZREP'"
if ((HOST_IN_PATH)); then
    DATASET_ZREP="$DATASET_ZREP/$SOURCE_HOST"
    # Listing must remain read-only.
    if [[ "$LIST_SNAPSHOTS" == false ]] && ! zfs list -H -o name "$DATASET_ZREP" >/dev/null 2>&1; then
        zfs create "$DATASET_ZREP"
    fi
fi
if [[ "$LIST_SNAPSHOTS" == true ]]; then
    zfs list -t all -r "$DATASET_ZREP/$VM_NAME"
    exit 0
fi

DATE=$(date +%Y-%m-%d--%H)
case "$VIRT_TYPE" in
    incus-*) ssh -o BatchMode=yes "syncoid-backup@$SOURCE_HOST" incus snapshot create "$VM_NAME" "zas-$FREQ-$DATE" </dev/null ;;
    lxd-*) ssh -o BatchMode=yes "syncoid-backup@$SOURCE_HOST" lxc snapshot "$VM_NAME" "zas-$FREQ-$DATE" </dev/null ;;
esac
platform=${VIRT_TYPE%-*}
case "$VIRT_TYPE" in
    *-ct)
        syncoid -r "${SSH_OPTS[@]}" "${ARGS_SYNCOID[@]}" "syncoid-backup@$SOURCE_HOST:tank/$platform/containers/$VM_NAME" "$DATASET_ZREP/$VM_NAME"
        ;;
    *-kvm)
        if ! zfs list -H -o name "$DATASET_ZREP/$VM_NAME" >/dev/null 2>&1; then
            zfs create "$DATASET_ZREP/$VM_NAME"
        fi
        for suffix in '' .block; do
            syncoid -r "${SSH_OPTS[@]}" "${ARGS_SYNCOID[@]}" "syncoid-backup@$SOURCE_HOST:tank/$platform/virtual-machines/$VM_NAME$suffix" "$DATASET_ZREP/$VM_NAME/$VM_NAME$suffix"
        done
        ;;
esac
