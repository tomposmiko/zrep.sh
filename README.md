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
exposes these in ZFS with a `snapshot-` prefix. Snapshot creation must succeed
before any transfer. An existing snapshot with the same hourly name will now
cause an explicit failure instead of silently replicating older evidence;
review/remove that snapshot through Incus/LXD before retrying in the same hour.
Concurrent runs against the same destination are not supported; serialize
scheduler invocations (for example with `flock`). The batch command continues
after job failures and exits nonzero if any job failed. This changes the former
always-success exit status; notification wrappers should handle it accordingly.

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
