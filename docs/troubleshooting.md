# Troubleshooting

Start with `make doctor` — it catches most of what follows.

## The runner is offline after a reboot

The service is a launchd user agent and needs a logged-in GUI session.

```bash
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser   # must print the runner user
launchctl print "gui/$(id -u)/actions.runner.quavon-dev.$(hostname -s)"
```

Fix: enable automatic login (see [vm-setup.md](vm-setup.md)), or log in over
screen sharing and keep the session alive.

## HTTP 404 when registering

The token cannot see the org's runner settings. A classic PAT needs `admin:org`;
a fine-grained PAT needs the org permission *Self-hosted runners: Read and
write*, and must be **approved by an org owner**. `read:org` alone returns 404,
not 403.

```bash
curl -sS -H "Authorization: Bearer $GITHUB_PAT" \
  https://api.github.com/orgs/quavon-dev/actions/runners
```

## HTTP 403 on the runner group

Custom runner groups need GitHub Team or Enterprise. Leave `RUNNER_GROUP=Default`
on a Free org.

## "A runner exists with the same name"

Two hosts share a hostname, or a VM was cloned after registration. Rename the
host (`scutil --set HostName ...`) or pass `--name`, then reinstall with
`--force`.

## Jobs stay queued forever

The labels in `runs-on:` must all be present on the runner. Check what the
runner actually advertises:

```bash
make status
```

`runs-on: [self-hosted, macOS, x64]` matches; `runs-on: macos-latest` never does
— that is a GitHub-hosted runner.

## A job fails because of leftover state

Persistent runners reuse `_work`. Either clean up in the workflow, or switch the
host to ephemeral mode:

```bash
make uninstall ARGS=--all
./bin/install.sh --ephemeral
```

## The runner stops mid-job

Usually sleep or a full disk.

```bash
pmset -g | head
df -h ~
du -sh ~/actions-runners/*/_work/*
```

## Reading the logs

```bash
make logs
ls -lt ~/actions-runners/*/_diag/
```

Worker logs (`Worker_*.log`) hold job output; `Runner_*.log` holds the listener.

## Full reset of one runner

```bash
./bin/uninstall.sh --name quavon-mac-02 --yes
./bin/install.sh --name quavon-mac-02
```

## Clearing an orphaned registration

If a VM disappeared before deregistering, delete it in
`https://github.com/organizations/quavon-dev/settings/actions/runners`, or:

```bash
curl -X DELETE -H "Authorization: Bearer $GITHUB_PAT" \
  https://api.github.com/orgs/quavon-dev/actions/runners/<runner_id>
```
