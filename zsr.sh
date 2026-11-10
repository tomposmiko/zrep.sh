#!/bin/bash
# Delete selected backup snapshots; never pass dataset names to zfs destroy.
set -euo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

usage() {
    cat <<'HELP'
Usage: zsr.sh [OPTIONS] PATTERN [PATTERN ...]

Preview snapshots whose NAME contains any literal PATTERN (not a regex).
Patterns must have at least 3 characters, contain a letter or digit, and use
only letters, digits, underscores, dots, colons or hyphens. Dataset names
are not searched. No snapshots are deleted by default.

  -h, --help             Show help without querying ZFS
  -d, --dataset DATASET  Limit to this subtree (default: tank/zrep)
                         Only tank/zrep and its descendants are accepted
      --delete           Execute the displayed deletion plan
      --confirm DATASET  Required with --delete; must exactly match --dataset
                         Deletion also requires an explicit --dataset option
      --max-delete N     Refuse plans over N snapshots (default: 100)
  --                     End options

Examples:
  zsr.sh --dataset tank/zrep/chief11 zas-daily-2026-10
  zsr.sh --dataset tank/zrep/chief11 --delete \
         --confirm tank/zrep/chief11 zas-daily-2026-10

Only individual snapshots are destroyed, without recursive/clone/force flags.
Stop concurrent replication/retention jobs before deletion. A failed destroy
stops the script; snapshots already deleted cannot be recovered by this script.
HELP
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

DATASET=tank/zrep
DATASET_EXPLICIT=false
DELETE=false
CONFIRM=""
MAX_DELETE=100
PATTERNS=()

# Validate every argument before calling ZFS (including when no args are given).
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -d|--dataset|--confirm|--max-delete)
            (($# >= 2)) && [[ -n "$2" ]] || fail "Missing value for $1"
            case "$1" in
                -d|--dataset) DATASET="$2"; DATASET_EXPLICIT=true ;;
                --confirm) CONFIRM="$2" ;;
                --max-delete) MAX_DELETE="$2" ;;
            esac
            shift 2 ;;
        --delete) DELETE=true; shift ;;
        --) shift; PATTERNS+=("$@"); break ;;
        -*) fail "Unknown option: $1 (use --help)" ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done
if ((${#PATTERNS[@]} == 0)); then
    usage >&2
    fail "At least one literal snapshot-name pattern is required"
fi
[[ "$DATASET" =~ ^tank/zrep(/[A-Za-z0-9][A-Za-z0-9_.:-]*)*$ ]] || fail "Dataset must be tank/zrep or a valid descendant"
[[ "$MAX_DELETE" =~ ^[0-9]{1,7}$ ]] || fail "Invalid --max-delete value"
MAX_DELETE=$((10#$MAX_DELETE))
((MAX_DELETE >= 1 && MAX_DELETE <= 1000000)) || fail "--max-delete must be between 1 and 1000000"
for pattern in "${PATTERNS[@]}"; do
    [[ ${#pattern} -ge 3 && "$pattern" =~ ^[A-Za-z0-9_.:-]+$ && "$pattern" =~ [A-Za-z0-9] ]] || fail "Unsafe or invalid literal pattern: '$pattern'"
done
if [[ "$DELETE" == true ]]; then
    [[ "$DATASET_EXPLICIT" == true && "$CONFIRM" == "$DATASET" ]] || fail "Deletion requires --dataset DATASET and --confirm with that exact DATASET"
else
    [[ -z "$CONFIRM" ]] || fail "--confirm requires --delete"
fi

# Capture the exit status directly. Never hide listing errors in a pipeline
# or process substitution. Validate the complete inventory before any destroy.
INVENTORY=$(zfs list -H -t snapshot -o name -s name -r "$DATASET")
PLAN=()
declare -A SEEN=()
while IFS= read -r snapshot; do
    [[ -n "$snapshot" ]] || continue
    # Exclude ZFS destroy list/range syntax (commas and percent signs), options,
    # shell metacharacters and malformed names even if inventory is unexpected.
    [[ "$snapshot" =~ ^tank/zrep(/[A-Za-z0-9][A-Za-z0-9_.:-]*)*@[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]] || fail "Invalid snapshot in ZFS inventory: '$snapshot'"
    owner=${snapshot%@*}
    [[ "$owner" == "$DATASET" || "$owner" == "$DATASET/"* ]] || fail "Snapshot outside requested subtree: '$snapshot'"
    name=${snapshot#*@}
    for pattern in "${PATTERNS[@]}"; do
        if [[ "$name" == *"$pattern"* ]]; then
            if [[ ! -v "SEEN[$snapshot]" ]]; then
                PLAN+=("$snapshot")
                SEEN[$snapshot]=1
            fi
            break
        fi
    done
done <<< "$INVENTORY"

count=${#PLAN[@]}
printf 'Dataset: %s\nSelected snapshots: %s\n' "$DATASET" "$count"
((count <= MAX_DELETE)) || fail "Plan exceeds --max-delete $MAX_DELETE; narrow the selection or explicitly raise the limit"
if ((count == 0)); then
    printf 'No matching snapshots.\n'
    exit 0
fi
printf '  %s\n' "${PLAN[@]}"
if [[ "$DELETE" == false ]]; then
    printf 'DRY RUN: nothing deleted. Use --delete --dataset DATASET --confirm DATASET to execute.\n'
    exit 0
fi
for snapshot in "${PLAN[@]}"; do
    printf 'Deleting %s\n' "$snapshot"
    zfs destroy "$snapshot"
done
printf 'Deleted %s snapshot(s).\n' "$count"
