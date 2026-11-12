# zrep.sh

Pull Incus/LXD snapshots with syncoid. Requires Bash 4.3+, GNU tools,
OpenZFS, SSH, syncoid and a source-side account able to create snapshots and
run the scoped ZFS commands. Configuration defaults to `/etc/zrep/zrep.conf`:

```
host-a:container-a:incus-ct
host-b:vm-b:incus-kvm
```

Supported types are `incus-ct`, `incus-kvm`, `lxd-ct`, and `lxd-kvm`.
Blank lines and full-line comments are ignored. Exactly three fields are
required. Source pools remain `tank/incus` and `tank/lxd`. The former example
fourth field `:external` was never implemented and is now explicitly rejected.

```
zrep.sh -s container-a -f daily
zrep.sh -s host-b:vm-b:incus-kvm -f weekly
zrep.sh --list vm-b
zrep-all.sh -f daily
```

The destination root `tank/zrep` must already exist. Containers replicate to
`tank/zrep/<guest>`. VMs replicate configuration and disk separately to
`tank/zrep/<guest>/<guest>` and `tank/zrep/<guest>/<guest>.block`. Guest names
must be unique across the config to prevent different hosts sharing a target.
`zrep.sh -E` inserts a source hostname beneath the root; batch mode retains the
default layout. List mode never creates datasets.

Snapshot names remain `zas-<frequency>-YYYY-MM-DD--HH`; Incus/LXD normally
exposes these in ZFS with a `snapshot-` prefix. If creation fails, replication
continues only after a read-only ZFS query verifies that exact snapshot already
exists on the source. VMs require it on both configuration and `.block` datasets
before either transfer starts. A warning reports reuse of the existing hourly
snapshot; it is not a newly captured recovery point. Missing snapshots or failed
verification stop the job. This uses the gateway's existing snapshot metadata
permission; no new source permissions or snapshot deletion are needed.
Concurrent runs against the same destination are not supported; serialize
scheduler invocations (for example with `flock`). The batch command continues
after job failures and exits nonzero if any job failed. This changes the former
always-success exit status; notification wrappers should handle it accordingly.

When syncoid fails, zrep adds a read-only comparison of source and backup snapshot
GUIDs for the failed dataset. The error explicitly reports when there are no
common snapshots, even if syncoid's original error only mentions bookmark
listing. Matching names alone do not establish a common snapshot. Failed queries
or malformed metadata are reported as an unavailable check, not as missing
history. Source bookmarks are not checked, so absence of common snapshots alone
does not prove a full replication is required. The original syncoid error and
exit status are preserved; no automatic reset, rename or deletion is performed.

## Retention and checks

`zrep-gc.sh [-f] [-s literal-substring] DATASET KEEP` defaults to dry run.
`KEEP` is a nonnegative count (at most nine digits) or a `YYYY-MM-DD` cutoff
in the local timezone. Counts retain the newest matching snapshots per dataset;
cutoffs remove matching snapshots strictly older than local midnight. A full
dataset path selects that exact subtree. A short name selects matching path
components beneath `tank`. Filters are literal, not regular expressions.
ZFS inventory failures abort. Inspect dry-run output before using `-f`.

`zrep-check.sh --noop -d 2 -w 8` checks leaf datasets beneath `tank/zrep`.
`--noop` does not require Slack credentials. Notifications read
`/etc/slack-notification.conf` only when needed. Puppet's backup metrics provide
a configuration-based inventory and detect an entirely missing guest; the
legacy checker only sees existing datasets and cannot detect that case.

## Instance configuration coverage

`zrep-coverage.sh` is a read-only Bash audit that starts with live Incus/LXD
instances, including stopped guests, rather than only existing configured
jobs. It compares each instance with `/etc/zrep/zrep.conf` and the destination
dataset layout. It reports missing/wrong source entries, destination collisions,
missing container/VM components and stale configuration for removed instances.
It lists only destination filesystem/volume names and types, not snapshots.
Unsupported projects and source storage layouts are reported explicitly.
Custom attached volumes, freshness, contents and restores remain separate checks.

```bash
zrep-coverage.sh --hosts-file /etc/zrep/coverage-hosts.txt --verbose
# A source without Puppet needs only the updated gateway and existing SSH key:
zrep-coverage.sh --host v201.sg.svfx --verbose
```

The audit also queries hosts already present in `zrep.conf`. Independent host
registration is necessary to detect a whole source missing from that config.
The sibling Puppet backup role collects managed Incus source registrations and
includes `v201.sg.svfx` explicitly by default. Additional unmanaged hosts can
be listed in `zrep_coverage_extra_hosts` or supplied with repeatable `--host`.
If SSH names differ between the inventory and config, explicitly map verified
equivalent names with `--host-alias v201=v201.sg.svfx`. Instance exclusions use
repeatable `--ignore-instance NAME` and apply literally across all hosts.

Each source must support the exact `zrep inventory` restricted-gateway request.
The updated gateway reads local Unix-socket APIs, detects Incus/LXD locally and
returns only instance identities and root storage metadata. No instance config
secrets are exposed. Source API/SSH failures and malformed/stale responses
produce alerts; valid empty inventories are accepted. Puppet is not required
on v201: rebuild and install the source bundle using the existing standalone
installer instructions before enabling the check. Old gateways deny the new
request. No new shell or general Incus administration permissions are granted.

On backup11, Puppet installs this script and runs it daily at 06:22 using the
existing direct Slack/email wrapper. One combined report goes to Slack and
root cron mail, using the same webhook as the Samba coverage audit. The wrapper
is not part of this standalone repository. The audit itself sends no messages,
runs no backups and modifies no datasets. Healthy runs are silent; exit 1
indicates findings and exit 2 means the audit could not run. `--extended-vault`
checks explicitly scheduled `zrep.sh -E` layouts; the standard batch layout is
the default. Run `bash tests/test_coverage.sh` for mocked SSH/ZFS coverage tests.

## Incus snapshot cleanup

`isr/isr.sh` cleans up Incus-managed snapshots of containers and VMs. Run it locally
as an Incus administrator. It uses the local socket, isolates client aliases and
remote settings, and requires either `--instance NAME` or `--all-instances`.
In a cluster, only instances on the local member are included. One project is
checked per run; the default project is `default`. LXD is not supported.

Every run previews by default. Optional literal patterns match snapshot names,
so `zas-daily` selects the usual zrep daily snapshots. Without patterns, provide
a retention option: all names then match, including manually created snapshots.

```sh
# Preview old daily snapshots, preserving five matching snapshots per instance.
bash isr/isr.sh --instance chief11 --older-than 14d --keep-at-least 5 zas-daily

# Preview all snapshot names, including manual snapshots, in the default project.
bash isr/isr.sh --project default --all-instances --before 2026-08-01 --keep-at-least 20

# Delete the selection after reviewing the same command without --delete/--confirm.
bash isr/isr.sh --project default --instance chief11 --older-than 14d \
  --keep-at-least 5 zas-daily --delete --confirm default/chief11
```

`--before` and `--older-than` use Incus creation timestamps, not dates embedded
in names. Snapshots exactly at a cutoff are kept. All supplied protections apply
together. `--keep-at-least N` preserves the newest N **matching** snapshots per
instance; matching snapshots protected by date/age count toward that minimum.
Its default is zero. The default deletion limit is 100 snapshots per run; use
`--max-delete N` to change it explicitly.

Deletion requires an explicit `--project` and an exact scope confirmation:
`--confirm default/chief11` for one instance, or `--confirm 'default/*'` with
`--all-instances`. Only `incus snapshot delete INSTANCE SNAPSHOT` is used,
without force flags. Instance deletion and raw ZFS snapshot deletion are never
used. The restricted backup account is not given cleanup permissions.

The script validates the complete selected inventory before deleting and
rechecks instance identity and snapshots before each deletion. Invalid metadata,
inventory changes and failed deletions stop the run. Stop concurrent snapshot,
replication, retention and instance-migration jobs: a race between the final
read and deletion is still possible. Earlier deletions cannot be undone.
Verify that required backups and incremental replication bases are retained;
this tool does not check the backup destination.

Requires Bash 4.3+, jq, GNU coreutils and an Incus client supporting
`snapshot list`/`snapshot delete`. Use `bash isr/isr.sh --help` for all options.
The legacy `lxdsr.sh` is unchanged. Run the mocked safety tests with
`bash isr/tests/test_isr.sh`; they do not contact Incus or delete real snapshots.

## Puppet integration

The sibling Puppet repository owns:

- `pts_only_shell::zrep`: the root-owned restricted login shell, forced SSH
  command and privileged validating gateway. It is installed whenever the
  backup account is managed; the legacy `only-shell` rules are not used.
- `pts_users::users::u_syncoid_backup`: the restricted key, account and sudo
  policy. Supplementary groups are cleared inclusively, including `sudo`,
  `ptsaccess` and any Incus/LXD administration groups. The only sudo command
  is `/usr/local/sbin/pts-zrep-source`, which validates every request.
- `pts_metrics::backups`: reads the same three-field config and default
  destination layout. VM freshness requires matching daily snapshots in both
  configuration and `.block` datasets. Extended vaults are not supported by the
  metrics collector and fail collection explicitly.

SSH accepts only public-key authentication from `/etc/ssh/auths/%u.pub` for
this account. A per-user ForceCommand also protects against alternate keys;
forwarding, PTY allocation, user SSH rc hooks and a general login shell are
disabled. The gateway runs no shell text and ignores account client configs.
It accepts zrep's default-project local instance snapshots, scoped ZFS reads
and sends, and creation/deletion of individual `syncoid_*` helper snapshots.
It denies dataset deletion, receive, rollback, property changes, clone/image
traversal, shell expansion, arbitrary pipelines and file redirection. Resumed
sends are decoded with a dry run and their target GUID must match an existing
snapshot under an allowed source path before sending any stream.

zrep passes `--no-clone-handling` to syncoid for containers and both VM
components. Incus/LXD clones may originate in images/; backing up instances
independently avoids granting access outside the scoped source trees. This
can use more backup space than preserving clone relationships. Transport and
resumable replication remain enabled. The gateway supports default lzop and
16M mbuffer pipelines (and their absence); other compression, buffer sizes,
bookmarks/holds and extra syncoid switches require an explicit policy review.

Apply the matching Puppet and zrep changes together: install the new zrep
client default before enforcing the source restrictions. Existing SSH sessions
must be closed after the privilege change; changing groups/ForceCommand does
not revoke the privileges of already-running sessions. Validate a new SSH
connection, full and incremental container/VM backup, an interrupted/resumed
transfer and a restore on a staging host before production rollout.
The repository tests generate traffic with upstream syncoid and mocked tools;
they do not establish compatibility with an unknown deployed version or test
real ZFS streams, sshd/PAM configuration, or restores.

`zsr.sh` selects backup snapshots by literal substring of the snapshot name.
It previews by default, validates arguments before querying ZFS, and limits
selection to `tank/zrep` or an explicitly requested subtree. Patterns must be
at least three characters and use only letters, digits, underscores, dots,
colons or hyphens. They must contain a letter or digit. Dataset names are not
searched. This replaces the former regex matching and immediate deletion.

```
zsr.sh --help
zsr.sh --dataset tank/zrep/chief11 zas-daily-2026-10
zsr.sh --dataset tank/zrep/chief11 --delete --confirm tank/zrep/chief11 zas-daily-2026-10
```

Date and count protections can be combined:

```
# Preview matching snapshots created before local midnight on October 1.
zsr.sh --dataset tank/zrep/chief11 --before 2026-10-01 zas-daily
# Preview all snapshots older than seven days, retaining at least five per dataset.
zsr.sh --dataset tank/zrep/chief11 --older-than 7d --keep-at-least 5
# Add --delete --confirm tank/zrep/chief11 to execute either preview's policy.
```

`--before` accepts a calendar date or a quoted date/time such as
`"2026-10-01 12:30:00+02:00"`. Without a timezone, local time is used.
`--older-than` accepts positive integer ages with `s`, `m`, `h`, `d`, or `w`
units (seconds, minutes, hours, 24-hour days, seven-day weeks). Future absolute
cutoffs and invalid metadata are rejected. Relative ages are resolved once
at startup. Snapshots exactly at a cutoff are protected.

Retention uses actual ZFS creation timestamps, not embedded name dates.
`--keep-at-least N` retains the newest N **matching** snapshots independently
for each dataset; unrelated snapshot series do not count. Recent matching
snapshots count towards that minimum. Overlapping patterns count each snapshot
once. If there are N or fewer matching snapshots, nothing in that dataset is
deleted. Equal creation timestamps are ordered by snapshot name for stable
selection. All supplied protections must permit deletion: combining an absolute
cutoff, minimum age and minimum count never weakens any one of them. The count
defaults to zero; no implicit minimum is added. Patterns are optional when a
retention option is specified. Without patterns, **all** snapshot series in
the subtree count towards the minimum and are eligible under the policy,
including syncoid helper snapshots. Supply a pattern such as `zas-daily` to
manage only that series. A bare invocation or options without any pattern or
retention option fail before querying ZFS.

Execution requires an explicit `--dataset` and an identical `--confirm` value.
Plans over 100 snapshots are rejected before deletion; `--max-delete N`
explicitly changes that limit. Unexpected inventory entries abort the whole
plan. Overlapping patterns are deduplicated, and only individual snapshot
names are passed to `zfs destroy`, without recursive, clone or force flags.
A destroy failure stops execution; earlier deletions cannot be rolled back.
Serialize deletion with replication/retention jobs. Preview and execution query
ZFS separately, so inspect the printed execution plan as well.

`lxdsr.sh` remains a legacy source helper: it currently only lists snapshots
and does not invoke its deletion function; its unused function also contains
old helper names. It is not the retention interface above.

## Validation

```
python3 -m unittest discover -s tests -v
shellcheck -x zsr.sh zrep.sh zrep-all.sh zrep-gc.sh zrep-check.sh _common.sh _zrep_common.sh
```

Tests use isolated command mocks and never contact hosts or modify ZFS.
The Puppet repository additionally tests SSH rule acceptance/rejection, backup
metrics, account ordering and the generated sudo rule. Actual source-side
syncoid compatibility and restoreability require testing in the deployed
environment; these tests do not establish either.
