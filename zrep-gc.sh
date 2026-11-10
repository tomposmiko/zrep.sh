#!/bin/bash

set -euo pipefail

DRY_RUN="true"
SNAP_FILTER=""

f_usage() {
    echo "Usage: $0 [-f] [-s <string>] <pool/fs> <keep>"
    echo "    -f          Actually delete snapshots (default is dry-run)"
    echo "    -s <string> Only delete snapshots whose name contains this string"
    echo "    <pool/fs>   ZFS dataset name (e.g. tank/data)"
    echo "    <keep>      Either a number (keep that many newest snapshots)"
    echo "                or a date (YYYY-MM-DD, keep snapshots newer than that date)"

    exit 1
}

f_echo_1() {
    if [ "$1" = "-n" ]; then
        shift

        echo -n "    $*"
    else
        echo "    $*"
    fi
}

f_process_args() {
    while getopts ":fs:" opt; do
        case "$opt" in
            f)
                DRY_RUN="false"
            ;;

            s)
               SNAP_FILTER="$OPTARG"
            ;;

            *)
               f_usage
            ;;
        esac
    done

    shift $((OPTIND - 1))

    [[ $# -eq 2 ]] || f_usage

    DATASET_PATH="$1"
    KEEP_VALUE="$2"
}

f_get_dataset_list() {
    local inventory dataset
    # Capture command status before parsing: process substitution hides failures.
    if [[ "$DATASET_PATH" == */* ]]; then
        inventory=$(zfs list -H -o name -r "$DATASET_PATH")
        mapfile -t DATASET_LIST <<< "$inventory"
    else
        inventory=$(zfs list -H -o name -r tank)
        DATASET_LIST=()
        while IFS= read -r dataset; do
            if [[ "/$dataset/" == *"/$DATASET_PATH/"* ]]; then
                DATASET_LIST+=("$dataset")
            fi
        done <<< "$inventory"
    fi

    if [ "${#DATASET_LIST[@]}" -eq 0 ]; then
        f_echo_1 "No such dataset found: '$DATASET_PATH'."

        exit 1
    fi
}

f_get_snapshot_list_filtered() {
    local dataset_path=$1

    local inventory snap_path snap_epoch
    inventory=$(zfs list -H -p -t snapshot -o name,creation -s creation -r "$dataset_path") || return $?
    while IFS=$'\t' read -r snap_path snap_epoch; do
        [[ "$snap_path" == "$dataset_path@"* ]] || continue
        [[ "${snap_path#*@}" == *"$SNAP_FILTER"* ]] || continue
        printf '%s\t%s\n' "$snap_path" "$snap_epoch"
    done <<< "$inventory"
}

f_get_snapshot_delete_list_based_on_count() {
    local dataset_path=$1

    local snap_count_to_keep=$((10#$KEEP_VALUE))

    local snap_path_list

    local inventory
    inventory=$(f_get_snapshot_list_filtered "$dataset_path")
    snap_path_list=()
    local snap_path snap_epoch
    while IFS=$'\t' read -r snap_path snap_epoch; do
        [[ -z "$snap_path" ]] || snap_path_list+=("$snap_path")
    done <<< "$inventory"

    local snap_count_total=${#snap_path_list[@]}

    if [ "$snap_count_total" -le "$snap_count_to_keep" ]; then
        f_echo_1 "Nothing to delete for ${dataset_path}, snapshots count: '$snap_count_total'."

        return 0
    fi

    local snap_delete_count=$(( snap_count_total - snap_count_to_keep ))

    # Take the oldest snapshots that need deletion
    SNAPSHOT_DELETE_LIST=( "${snap_path_list[@]:0:$snap_delete_count}" )
}

f_get_snapshot_delete_list_based_on_date() {
    local dataset_path=$1

    local cutoff_epoch
    cutoff_epoch=$( date -d "$KEEP_VALUE" +%s )

    SNAPSHOT_DELETE_LIST=()

    local inventory
    inventory=$(f_get_snapshot_list_filtered "$dataset_path")
    local snap_epoch
    local snap_path

    while IFS=$'\t' read -r snap_path snap_epoch; do
        [[ -n "$snap_path" ]] || continue
        [[ "$snap_epoch" =~ ^[0-9]+$ ]] || { echo "Invalid snapshot creation time" >&2; exit 1; }

        if [ "$snap_epoch" -lt "$cutoff_epoch" ]; then
            SNAPSHOT_DELETE_LIST+=( "$snap_path" )
        fi
    done <<< "$inventory"
}

f_get_snapshot_delete_list_final() {
    local dataset_path=$1

    if [[ "$KEEP_VALUE" =~ ^[0-9]+$ ]]; then

        f_get_snapshot_delete_list_based_on_count "$dataset_path"

    elif [[ "$KEEP_VALUE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then

        f_get_snapshot_delete_list_based_on_date "$dataset_path"

    else
        echo

        echo "Invalid KEEP_VALUE argument: '$KEEP_VALUE'. Must be a date (YYYY-MM-DD) or a number (XX)."

        echo

        f_usage
    fi

    if [ ${#SNAPSHOT_DELETE_LIST[@]} -eq 0 ]; then
        f_echo_1 "No snapshots to delete for '$dataset_path'."
    fi
}

f_delete_snapshots() {
    for snap_path in "${SNAPSHOT_DELETE_LIST[@]}"; do
        local snap_name=${snap_path##*@}

        if [ "$DRY_RUN" = "true" ]; then
            f_echo_1 "Would delete '$snap_name'"
        else
            f_echo_1 -n "Deleting '${snap_name}'... "

            zfs destroy "$snap_path"

            echo "done."
        fi
    done
}

f_process_dataset() {
    local dataset_name=$1

    SNAPSHOT_DELETE_LIST=()

    echo "Start dataset processing: '${dataset_name}'"

    echo

    f_get_snapshot_delete_list_final "$dataset_name"

    f_delete_snapshots "$dataset_name"

    echo

    f_echo_1 "Total number of snapshots: '${#SNAPSHOT_DELETE_LIST[@]}'"

    echo

    echo "Finish dataset processing: '${dataset_name}'"

    echo
}


f_process_args "$@"

if [[ "$KEEP_VALUE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    date -d "$KEEP_VALUE" +%s >/dev/null
elif [[ ! "$KEEP_VALUE" =~ ^[0-9]{1,9}$ ]]; then
    f_usage
fi

f_get_dataset_list

for DATASET_NAME in "${DATASET_LIST[@]}"; do
    f_process_dataset "$DATASET_NAME"
done
