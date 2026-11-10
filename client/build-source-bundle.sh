#!/bin/bash
# Build a self-contained installer using the reviewed sibling Puppet gateway.
set -euo pipefail
here=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
puppet="$here/../../puppet"
output=/tmp/zrep-source-install.tar.gz
while (($#)); do
    case "$1" in
        --puppet|--output)
            (($# >= 2)) || { printf 'Missing argument for %s\n' "$1" >&2; exit 1; }
            case "$1" in --puppet) puppet=$2 ;; --output) output=$2 ;; esac
            shift 2 ;;
        --help|-h)
            printf 'Usage: bash %s [--puppet PATH] [--output NEW_ARCHIVE]\n' "$0"
            exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
done
output=$(realpath -m -- "$output")
[[ ! -e "$output" && ! -L "$output" ]] || { printf 'Output already exists: %s\n' "$output" >&2; exit 1; }
staging=$(mktemp -d "$(dirname -- "$output")/.zrep-build-XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bundle="$staging/zrep-source-install"
mkdir "$bundle"
for name in pts-zrep-source pts-zrep-ssh; do
    install -m 0755 -- "$puppet/modules/pts_only_shell/files/usr/local/sbin/$name" "$bundle/$name"
done
install -m 0755 -- "$here/source-install/install.sh" "$bundle/install.sh"
install -m 0644 -- "$here/source-install/README.md" "$bundle/README.md"
revision=$(git -C "$puppet" rev-parse HEAD)
printf 'Puppet checkout HEAD: %s\nGateway files copied from working tree; SHA256SUMS identifies exact payloads.\n' "$revision" > "$bundle/PROVENANCE.txt"
(
    cd "$bundle"
    sha256sum PROVENANCE.txt README.md install.sh pts-zrep-source pts-zrep-ssh > SHA256SUMS
)
tar -czf "$staging/archive.tar.gz" -C "$staging" zrep-source-install
# Same-filesystem hard link publishes the complete archive without replacing an existing file.
ln -- "$staging/archive.tar.gz" "$output"
printf '%s\n' "$output"
