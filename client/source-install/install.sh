#!/bin/bash
# Install the standalone zrep source policy on an existing Linux account.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C

ACCOUNT=syncoid-backup
GATEWAY=/usr/local/sbin/pts-zrep-source
LAUNCHER=/usr/local/sbin/pts-zrep-ssh
KEYS=/etc/ssh/auths/syncoid-backup.pub
SSH_POLICY=/etc/ssh/zrep-source.conf
SSH_CONFIG=/etc/ssh/sshd_config
SUDO_POLICY=/etc/sudoers.d/zrep-source
SSH_OPTIONS=(
    "authorizedkeysfile $KEYS"
    'authenticationmethods publickey'
    'passwordauthentication no'
    'kbdinteractiveauthentication no'
    "forcecommand $LAUNCHER"
    'disableforwarding yes'
    'permittty no'
    'permituserrc no'
)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: bash install.sh --key FILE --backup-address IP [OPTIONS]
  --backup-host HOST          Client hostname as seen by sshd (default: backup11)
  --replace-sudo-rule PATH     Replace an obsolete dedicated sudo file (repeatable)
  --apply                      Install and reload SSH; default is preview
  --help                       Show this help
Requires root, an existing syncoid-backup account, and installed dependencies.
No packages are installed and no network requests are made.
HELP
}

key_line() {
    local line key=''
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ -z "$key" ]] || die 'Supply exactly one plain public key'
        [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\ [A-Za-z0-9+/=]+(\ [^$'\r\n']+)?$ ]] || die 'Invalid public key or existing key options'
        key=$line
    done < "$1"
    [[ -n "$key" ]] || die 'Public key is empty'
    printf 'restrict,command="%s" %s\n' "$LAUNCHER" "$key"
}

verify_sudo() {
    local grants
    grants=$(awk -v account="$ACCOUNT" '
        index($0, "User " account " may run the following commands on ") == 1 {found=1; next}
        found {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length) print}
        END {if (!found) exit 1}
    ') || return 1
    # sudo may print these independent tags in either order. Keep the run-as
    # identity, command and single-grant requirement exact in both cases.
    if [[ "$grants" != "(root) NOPASSWD: NOSETENV: $GATEWAY *" &&
          "$grants" != "(root) NOSETENV: NOPASSWD: $GATEWAY *" ]]; then
        printf 'Extra or unexpected sudo grants:\n%s\n' "$grants" >&2
        return 1
    fi
}

verify_ssh() {
    local actual expected
    actual=$(cat)
    for expected in "${SSH_OPTIONS[@]}"; do
        if ! grep -Fxq -- "$expected" <<< "$actual"; then
            printf 'Effective SSH policy missing: %s\n' "$expected" >&2
            return 1
        fi
    done
}

trusted_path() {
    local path=$1 parent owner mode
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* ]] || die "Invalid policy path: $path"
    [[ ! -e "$path" || -f "$path" ]] || die "Not a regular file: $path"
    parent=$path
    while :; do
        [[ ! -L "$parent" ]] || die "Symlink in managed path: $parent"
        if [[ "$parent" != "$path" && -e "$parent" ]]; then
            read -r owner mode < <(stat -c '%u %a' -- "$parent")
            if [[ "$owner" != 0 ]] || (( (8#$mode & 8#022) != 0 )); then
                die "Untrusted policy directory: $parent"
            fi
        fi
        [[ "$parent" != / ]] || break
        parent=$(dirname -- "$parent")
    done
}

save_file() {
    local path=$1 stored
    [[ ! -v "saved[$path]" ]] || return 0
    trusted_path "$path"
    stored=-
    if [[ -e "$path" ]]; then
        stored="$backup/${#paths[@]}"
        cp -a -- "$path" "$stored"
    fi
    printf '%s\t%s\n' "$path" "$stored" >> "$backup/files.tsv"
    saved["$path"]=$stored
    paths+=("$path")
}

write_file() {
    local path=$1 source=$2 mode=$3 parent directory temporary i
    local -a missing=()
    save_file "$path"
    parent=$(dirname -- "$path")
    while [[ ! -d "$parent" ]]; do
        missing+=("$parent")
        parent=$(dirname -- "$parent")
    done
    for ((i=${#missing[@]}-1; i>=0; i--)); do
        directory=${missing[i]}
        install -d -o root -g root -m 0755 -- "$directory"
        created_dirs+=("$directory")
    done
    temporary=$(mktemp "$(dirname -- "$path")/.zrep-XXXXXX")
    temporary_files+=("$temporary")
    install -o root -g root -m "$mode" -- "$source" "$temporary"
    mv -fT -- "$temporary" "$path"
}

restore_files() {
    local path stored failed=0 i
    for ((i=${#paths[@]}-1; i>=0; i--)); do
        path=${paths[i]}
        stored=${saved[$path]}
        if [[ "$stored" == - ]]; then
            rm -f -- "$path" || failed=1
        else
            cp -a -- "$stored" "$path" || failed=1
        fi
    done
    for ((i=${#created_dirs[@]}-1; i>=0; i--)); do
        rmdir -- "${created_dirs[i]}" || failed=1
    done
    return "$failed"
}

finish() {
    local status=$? recovery_failed=0 temporary
    trap - EXIT INT TERM
    # Remove only temporary files allocated by this invocation.
    for temporary in "${temporary_files[@]}"; do
        rm -f -- "$temporary" || recovery_failed=1
    done
    if (( ! completed )); then
        printf 'Install failed; restoring files and account settings from %s\n' "$backup" >&2
        restore_files || recovery_failed=1
        if (( account_changed )); then
            usermod -G "$old_groups" -s "$old_shell" "$ACCOUNT" || recovery_failed=1
        fi
        if sshd -t; then
            systemctl reload "$service" || recovery_failed=1
        else
            recovery_failed=1
        fi
        if (( recovery_failed )); then
            printf 'Automatic recovery incomplete; use the administrator session and %s\n' "$backup" >&2
        fi
        (( status != 0 )) || status=1
    fi
    exit "$status"
}

platform_checks() {
    local name
    (( EUID == 0 )) || die 'Run as root, including for preview'
    for name in sshd visudo sudo usermod systemctl ssh-keygen getent stat install mktemp cp mv rm rmdir awk grep tail cmp readlink dirname chmod cat; do
        command -v "$name" >/dev/null || die "Missing prerequisite: $name"
    done
    for name in /usr/bin/python3 /usr/bin/sudo /usr/sbin/zfs /usr/sbin/zpool; do
        [[ -x "$name" ]] || die "Missing executable: $name"
    done
    [[ -x /usr/bin/incus || -x /usr/bin/lxc || -x /snap/bin/lxc ]] || die 'Missing Incus/LXD client'
}

main() {
    local key_file='' address='' host=backup11 apply=0 argument line
    local account_record uid primary_gid name group members group_gid group_inventory
    local here restricted_key obsolete_rule
    local -a obsolete=() supplementary=()
    # EXIT runs after Bash unwinds function locals on some failure paths.
    # Keep recovery state global so the trap can always access it.
    backup='' account_changed=0 completed=0 old_shell='' old_groups='' service=''
    declare -ga paths=() created_dirs=() temporary_files=()
    declare -gA saved=()
    while (($#)); do
        argument=$1
        case "$argument" in
            --key|--backup-address|--backup-host|--replace-sudo-rule)
                (($# >= 2)) || die "Missing argument for $argument"
                case "$argument" in
                    --key) key_file=$2 ;;
                    --backup-address) address=$2 ;;
                    --backup-host) host=$2 ;;
                    --replace-sudo-rule) obsolete+=("$2") ;;
                esac
                shift 2 ;;
            --apply) apply=1; shift ;;
            --help|-h) usage; return ;;
            *) die "Unknown argument: $argument" ;;
        esac
    done
    [[ -n "$key_file" && -n "$address" ]] || { usage; return 1; }
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ && "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die 'Invalid client IP/hostname'
    platform_checks
    account_record=$(getent passwd "$ACCOUNT") || die "Missing account: $ACCOUNT"
    IFS=: read -r _ _ uid primary_gid _ _ old_shell <<< "$account_record"
    [[ "$uid" != 0 && "$uid" =~ ^[0-9]+$ ]] || die 'Backup account must not have UID 0'
    IFS=: read -r group _ _ _ < <(getent group "$primary_gid")
    [[ "$group" == "$ACCOUNT" ]] || die 'Expected dedicated syncoid-backup primary group'
    group_inventory=$(getent group)
    while IFS=: read -r group _ group_gid members; do
        if [[ ",$members," == *",$ACCOUNT,"* && "$group_gid" != "$primary_gid" ]]; then
            supplementary+=("$group")
        fi
    done <<< "$group_inventory"
    old_groups=$(IFS=,; printf '%s' "${supplementary[*]}")
    for obsolete_rule in "${obsolete[@]}"; do
        [[ "$obsolete_rule" =~ ^/etc/sudoers.d/[A-Za-z0-9_-]+$ && "$obsolete_rule" != "$SUDO_POLICY" && -f "$obsolete_rule" ]] || die "Invalid obsolete sudo rule: $obsolete_rule"
        trusted_path "$obsolete_rule"
    done
    here=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
    [[ -f "$here/pts-zrep-source" && -f "$here/pts-zrep-ssh" ]] || die 'Missing bundled gateways; run the bundle builder first'
    restricted_key=$(key_line "$key_file")
    ssh-keygen -l -f "$key_file" >/dev/null
    sshd -t
    visudo -c
    for name in ssh sshd; do
        if systemctl is-active --quiet "$name"; then service=$name; break; fi
    done
    [[ -n "$service" ]] || die 'No active systemd ssh/sshd service'
    # Even preview checks syntax and connection identity without changing files.
    sshd -T -C "user=$ACCOUNT,host=$host,addr=$address" >/dev/null
    for name in "$GATEWAY" "$LAUNCHER" "$KEYS" "$SSH_POLICY" "$SSH_CONFIG" "$SUDO_POLICY"; do
        trusted_path "$name"
    done
    printf 'Install %s, %s, %s, %s, %s\n' "$GATEWAY" "$LAUNCHER" "$KEYS" "$SSH_POLICY" "$SUDO_POLICY"
    printf 'Append account policy Include to %s; reject conflicting earlier Match rules\n' "$SSH_CONFIG"
    printf 'Replace obsolete sudo files: %s\n' "${obsolete[*]:-(none)}"
    printf 'Clear supplementary groups [%s]; set shell to %s\n' "$old_groups" "$LAUNCHER"
    printf 'Validate effective sudo/SSH policy; reload %s. No packages/network/Git changes.\n' "$service"
    if (( ! apply )); then
        printf 'Preview only. Repeat with --apply to install. Keep an administrator session open.\n'
        return
    fi
    backup=$(mktemp -d /root/zrep-source-backup-XXXXXX)
    chmod 0700 "$backup"
    printf '%s\t%s\n' "$old_shell" "$old_groups" > "$backup/account.tsv"
    printf 'Rollback originals: %s\n' "$backup"
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    write_file "$GATEWAY" "$here/pts-zrep-source" 0755
    write_file "$LAUNCHER" "$here/pts-zrep-ssh" 0755
    printf '%s\n' "$restricted_key" > "$backup/key.new"
    write_file "$KEYS" "$backup/key.new" 0644
    printf '%s ALL = (root) NOPASSWD: NOSETENV: %s *\n' "$ACCOUNT" "$GATEWAY" > "$backup/sudo.new"
    write_file "$SUDO_POLICY" "$backup/sudo.new" 0440
    for obsolete_rule in "${obsolete[@]}"; do
        save_file "$obsolete_rule"
        rm -- "$obsolete_rule"
    done
    {
        printf 'Match User %s\n' "$ACCOUNT"
        printf '    %s\n' "${SSH_OPTIONS[@]}"
        printf 'Match all\n'
    } > "$backup/ssh.new"
    write_file "$SSH_POLICY" "$backup/ssh.new" 0644
    # Match all does not restore the global parser context: append after global directives.
    printf '\nMatch all\n    Include %s\n' "$SSH_POLICY" > "$backup/include.new"
    if ! tail -c "$(stat -c %s "$backup/include.new")" "$SSH_CONFIG" | cmp -s - "$backup/include.new"; then
        cat "$SSH_CONFIG" "$backup/include.new" > "$backup/sshd.new"
        write_file "$SSH_CONFIG" "$backup/sshd.new" 0600
    fi
    visudo -c
    sshd -t
    sshd -T -C "user=$ACCOUNT,host=$host,addr=$address" | verify_ssh
    account_changed=1
    usermod -G '' -s "$LAUNCHER" "$ACCOUNT"
    sudo -l -U "$ACCOUNT" | verify_sudo
    systemctl reload "$service"
    completed=1
    finish
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
