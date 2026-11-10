# Standalone zrep source restrictions

The installer and bundle builder are Bash scripts. The included command gateway
retains its existing Python implementation. This bundle installs the same source
gateway as Puppet without requiring Puppet on the source host.
It targets an existing Linux `syncoid-backup` account with a
dedicated primary group of the same name and an active systemd `ssh` or `sshd`
service. It supports the default Incus/LXD project and ZFS source paths beneath
`tank/{incus,lxd}/{containers,virtual-machines}`. The account's public key is an
explicit input; no production key or private key is bundled.

Install the matching zrep client (`ab1ed99` or later, including its helpers) on
the backup server first: `--no-clone-handling` is required. Serialize the rollout
with backup jobs. Keep a separate administrator connection open throughout.

## Prepare and preview

Copy this archive and the backup server's plain OpenSSH public key to v201 using
your administrator account. Extract beneath a root-owned directory. As root:

```bash
cd /root
tar -xzf /path/to/zrep-source-install.tar.gz
cd zrep-source-install
sha256sum -c SHA256SUMS
bash install.sh --key /root/backup11.pub \
  --backup-address BACKUP_SERVER_IP --backup-host BACKUP_SERVER_HOSTNAME
```

Use the address and hostname sshd sees for the backup server, including NAT if
present. The connection identity is used to verify effective SSH Match settings.
Checksums detect accidental corruption; transfer the bundle through a trusted
channel. Review `PROVENANCE.txt` and the included gateway before running it.

The preview checks prerequisites and existing SSH/sudo syntax and prints the
intended changes. It makes no system changes and does not reload SSH. Installation
does not download packages or access the network. Dependencies must already be
installed: Bash 4.3+, GNU coreutils, Python 3 (for the gateway), sudo/visudo,
OpenSSH server/client utilities, usermod, systemd, ZFS and an Incus/LXD client.
lzop/mbuffer remain optional transport dependencies.

## Install

Inspect `sudo -l -U syncoid-backup` and existing sudoers entries. If an obsolete
dedicated rule grants broader privileges, name its exact file explicitly:

```bash
bash install.sh --key /root/backup11.pub \
  --backup-address BACKUP_SERVER_IP --backup-host BACKUP_SERVER_HOSTNAME \
  --replace-sudo-rule /etc/sudoers.d/OLD_DEDICATED_BACKUP_RULE --apply
```

Omit `--replace-sudo-rule` if there is no obsolete file; repeat it for multiple
dedicated rules. Do not name a shared administrator policy. Global or shared
rules must be narrowed manually. The installer refuses success unless the
effective sudo listing contains exactly its single gateway grant. Unfamiliar
sudo listing formats fail closed and trigger rollback as well.

The installer:

1. Saves original files, modes/ownership, shell and supplementary groups in a
   new root-only `/root/zrep-source-backup-*` directory.
2. Installs root-owned `/usr/local/sbin/pts-zrep-{source,ssh}` and replaces
   `/etc/ssh/auths/syncoid-backup.pub` with the supplied restricted key.
3. Installs `/etc/sudoers.d/zrep-source` and removes only explicitly named old
   sudo files. Clears all supplementary groups and sets the restricted login shell.
4. Installs `/etc/ssh/zrep-source.conf` and appends its Include after a `Match all`
   in `/etc/ssh/sshd_config`, keeping Match rules after global-only directives.
   Conflicting earlier Match rules cause verification to fail and roll back.
5. Validates sudoers, SSH syntax and effective SSH policy for the supplied client
   identity, then reloads the active SSH service.

It refuses symlinks or non-root-owned/group-writable policy directories. It
does not create accounts, change passwords, terminate sessions or touch ZFS
datasets. If an installation step fails, it attempts to restore the saved files
and account settings and reload the original SSH configuration. An interrupted
process or host failure can require manual recovery.

## Verify

From the backup server, use fresh SSH connections:

```bash
ssh -o BatchMode=yes syncoid-backup@v201.sg.svfx 'echo -n'
ssh -o BatchMode=yes syncoid-backup@v201.sg.svfx id
```

The first must succeed and `id` must be denied. Check `sudo -l -U syncoid-backup`
on v201, then run a full/incremental guest backup and a restore check. Existing
sessions/processes retain privileges: explicitly close old backup connections
and review remaining processes before considering the rollout complete.

For manual recovery, `files.tsv` maps each changed path to its original backup
file; `-` means the path did not previously exist. Restore those files with
their saved ownership/modes, remove newly created files, and use `account.tsv`
(first field: shell, second field: comma-separated groups) to restore the account
with usermod. Validate with `visudo -c` and `sshd -t`
before reloading SSH. Restoring the old policy also restores its old privileges.
