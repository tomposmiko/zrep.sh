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

    [ $# -ne 2 ] && f_usage

    DATASET_PATH="$1"
    KEEP_VALUE="$2"
}

f_get_dataset_list() {
    if [[ "$DATASET_PATH" == tank/zrep/* ]] || [[ "$DATASET_PATH" == tank/zrb/* ]]; then
        mapfile -t DATASET_LIST < <(
            zfs list -H -o name -r "$DATASET_PATH" | grep "^${DATASET_PATH}"
        )
    else
         mapfile -t DATASET_LIST < <(
             zfs list -H -o name -r tank | grep "/${DATASET_PATH}"
        )
    fi

    if [ "${#DATASET_LIST[@]}" -eq 0 ]; then
        f_echo_1 "No such dataset found: '$DATASET_PATH'."

        exit 1
    fi
}

f_get_snapshot_list_filtered() {
    local dataset_path=$1

    local grep_expr="^${dataset_path}@"

    if [ -n "$SNAP_FILTER" ]; then
        grep_expr="^${dataset_path}@.*${SNAP_FILTER}"
    fi

    zfs list -H -t snapshot -o name,creation -s creation -r "$dataset_path" | grep -E "$grep_expr" || true
}

f_get_snapshot_delete_list_based_on_count() {
    local dataset_path=$1

    local snap_count_to_keep="$KEEP_VALUE"

    local snap_path_list

    mapfile -t snap_path_list < <(
        f_get_snapshot_list_filtered "$dataset_path" | awk '{print $1}'
    )

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

    local snap_date
    local snap_epoch
    local snap_path

    while IFS=$'\t' read -r snap_path snap_date; do
        snap_epoch=$( date -d "$snap_date" +%s )

        if [ "$snap_epoch" -lt "$cutoff_epoch" ]; then
            SNAPSHOT_DELETE_LIST+=( "$snap_path" )
        fi
    done < <( f_get_snapshot_list_filtered "$dataset_path" )
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

f_get_dataset_list

for DATASET_NAME in "${DATASET_LIST[@]}"; do
    f_process_dataset "$DATASET_NAME"
done
