#!/bin/bash
# Delete selected backup snapshots; never pass dataset names to zfs destroy.
set -euo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

usage() {
    cat <<'HELP'
Usage: zsr.sh [OPTIONS] [PATTERN ...]

Preview snapshots whose NAME contains any literal PATTERN (not a regex).
With no patterns, retention options apply to ALL snapshots in the subtree.
Specify at least one pattern or --before, --older-than or --keep-at-least.
Patterns must have at least 3 characters, contain a letter or digit, and use
only letters, digits, underscores, dots, colons or hyphens. Dataset names
are not searched. No snapshots are deleted by default.

  -h, --help             Show help without querying ZFS
  -d, --dataset DATASET  Limit to this subtree (default: tank/zrep)
                         Only tank/zrep and its descendants are accepted
      --delete           Execute the displayed deletion plan
      --confirm DATASET  Required with --delete; must exactly match --dataset
                         Deletion also requires an explicit --dataset option
      --before DATE      Select only snapshots created strictly before DATE
                         YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS][Z|+HH:MM]
                         Local time unless a timezone is supplied; date-only
                         means midnight. Future cutoffs are rejected.
      --older-than AGE   Protect snapshots newer than AGE (e.g. 7d, 12h)
                         Units: s, m, h, d, w (fixed elapsed time)
      --keep-at-least N  Keep N newest MATCHING snapshots per dataset
                         Matching snapshots protected by date/age count too
      --max-delete N     Refuse plans over N snapshots (default: 100)
  --                     End options

Examples:
  zsr.sh --dataset tank/zrep/chief11 zas-daily-2026-10
  zsr.sh --dataset tank/zrep/chief11 --delete \
         --confirm tank/zrep/chief11 zas-daily-2026-10

All specified date, age and count protections apply together. Dates use ZFS
creation times, not dates embedded in names. Snapshots at a cutoff are kept.
Example: zsr.sh --dataset tank/zrep/chief11 --older-than 7d --keep-at-least 5

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
BEFORE=""
OLDER_THAN=""
KEEP_AT_LEAST=0
RETENTION=false
PATTERNS=()

# Validate every argument before calling ZFS (including when no args are given).
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -d|--dataset|--confirm|--max-delete|--before|--older-than|--keep-at-least)
            (($# >= 2)) && [[ -n "$2" ]] || fail "Missing value for $1"
            case "$1" in
                -d|--dataset) DATASET="$2"; DATASET_EXPLICIT=true ;;
                --confirm) CONFIRM="$2" ;;
                --max-delete) MAX_DELETE="$2" ;;
                --before) BEFORE="$2"; RETENTION=true ;;
                --older-than) OLDER_THAN="$2"; RETENTION=true ;;
                --keep-at-least) KEEP_AT_LEAST="$2"; RETENTION=true ;;
            esac
            shift 2 ;;
        --delete) DELETE=true; shift ;;
        --) shift; PATTERNS+=("$@"); break ;;
        -*) fail "Unknown option: $1 (use --help)" ;;
        *) PATTERNS+=("$1"); shift ;;
    esac
done
if [[ ${#PATTERNS[@]} == 0 && "$RETENTION" == false ]]; then
    usage >&2
    fail "Specify a literal snapshot-name pattern or a retention option"
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

# Resolve relative ages once so every dataset uses the same cutoff.
NOW=$(date +%s)
CUTOFF=$NOW
[[ "$KEEP_AT_LEAST" =~ ^[0-9]{1,7}$ ]] || fail "Invalid --keep-at-least count"
KEEP_AT_LEAST=$((10#$KEEP_AT_LEAST))
((KEEP_AT_LEAST <= 1000000)) || fail "--keep-at-least exceeds 1000000"
if [[ -n "$BEFORE" ]]; then
    [[ "$BEFORE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})?)?$ ]] || fail "Invalid --before date format"
    before_epoch=$(date -d "$BEFORE" +%s) || fail "Invalid --before date"
    ((before_epoch >= 0 && before_epoch <= NOW)) || fail "--before must be between the Unix epoch and now"
    CUTOFF=$before_epoch
fi
if [[ -n "$OLDER_THAN" ]]; then
    [[ "$OLDER_THAN" =~ ^([0-9]{1,7})([smhdw])$ ]] || fail "Invalid --older-than age; use e.g. 7d or 12h"
    amount=$((10#${BASH_REMATCH[1]}))
    unit=${BASH_REMATCH[2]}
    ((amount > 0)) || fail "--older-than must be positive"
    case "$unit" in
        s) seconds=1 ;; m) seconds=60 ;; h) seconds=3600 ;;
        d) seconds=86400 ;; w) seconds=604800 ;;
    esac
    age_cutoff=$((NOW - amount * seconds))
    ((age_cutoff >= 0)) || fail "--older-than extends before the Unix epoch"
    if ((age_cutoff < CUTOFF)); then CUTOFF=$age_cutoff; fi
fi

# Capture the exit status directly. Never hide listing errors in a pipeline
# or process substitution. Validate the complete inventory before any destroy.
if [[ "$RETENTION" == true ]]; then
    INVENTORY=$(zfs list -H -p -t snapshot -o name,creation -s creation -r "$DATASET")
else
    INVENTORY=$(zfs list -H -t snapshot -o name -s name -r "$DATASET")
fi
PLAN=()
declare -A SEEN=() CREATED=()
while IFS= read -r row; do
    snapshot=$row
    created=0
    if [[ "$RETENTION" == true && -n "$row" ]]; then
        [[ "$row" == *$'\t'* ]] || fail "Missing snapshot creation metadata"
        snapshot=${row%%$'\t'*}
        created=${row#*$'\t'}
        [[ "$created" =~ ^[0-9]{1,12}$ ]] || fail "Invalid snapshot creation timestamp"
        created=$((10#$created))
        ((created <= NOW)) || fail "Future snapshot creation timestamp"
    fi
    [[ -n "$snapshot" ]] || continue
    # Exclude ZFS destroy list/range syntax (commas and percent signs), options,
    # shell metacharacters and malformed names even if inventory is unexpected.
    [[ "$snapshot" =~ ^tank/zrep(/[A-Za-z0-9][A-Za-z0-9_.:-]*)*@[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]] || fail "Invalid snapshot in ZFS inventory: '$snapshot'"
    owner=${snapshot%@*}
    [[ "$owner" == "$DATASET" || "$owner" == "$DATASET/"* ]] || fail "Snapshot outside requested subtree: '$snapshot'"
    if [[ -v "CREATED[$snapshot]" && "${CREATED[$snapshot]}" != "$created" ]]; then
        fail "Conflicting creation metadata for '$snapshot'"
    fi
    CREATED[$snapshot]=$created
    name=${snapshot#*@}
    matched=false
    if ((${#PATTERNS[@]} == 0)); then matched=true; fi
    for pattern in "${PATTERNS[@]}"; do
        if [[ "$name" == *"$pattern"* ]]; then
            matched=true
            break
        fi
    done
    if [[ "$matched" == true && ! -v "SEEN[$snapshot]" ]]; then
        PLAN+=("$snapshot")
        SEEN[$snapshot]=1
    fi
done <<< "$INVENTORY"

if [[ "$RETENTION" == true && ${#PLAN[@]} -gt 0 ]]; then
    # Rank all matches before applying cutoffs. Recent matches count towards
    # the minimum; unrelated snapshot series do not.
    ranked=$(for snapshot in "${PLAN[@]}"; do
        printf '%s\t%s\n' "$snapshot" "${CREATED[$snapshot]}"
    done | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1)
    PLAN=()
    declare -A RANK=()
    while IFS=$'\t' read -r snapshot created; do
        owner=${snapshot%@*}
        rank=$(( ${RANK[$owner]:-0} + 1 ))
        RANK[$owner]=$rank
        if ((rank > KEEP_AT_LEAST && created < CUTOFF)); then
            PLAN+=("$snapshot")
        fi
    done <<< "$ranked"
fi

count=${#PLAN[@]}
if [[ "$RETENTION" == true ]]; then
    printf 'Creation cutoff (exclusive epoch): %s; keep newest matches per dataset: %s\n' "$CUTOFF" "$KEEP_AT_LEAST"
fi
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
