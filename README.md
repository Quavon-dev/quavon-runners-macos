# quavon-runners-macos

Self-hosted GitHub Actions runners for the **quavon-dev** org on macOS.

The runner runs **directly on the VM** — no Docker. The macOS instance *is* the
isolation boundary, and nested containerisation on macOS buys nothing but pain
(no native Linux containers, no nested virtualisation on most hosts).
Provisioning is idempotent: clone this repo on a new VM, run one command, and
the machine registers itself with the org.

## Quick start on a new VM

```bash
git clone https://github.com/quavon-dev/quavon-runners-macos.git ~/quavon-runners-macos
cd ~/quavon-runners-macos
./bootstrap.sh
```

`bootstrap.sh` creates `.env` (prompting for the org and PAT), runs the health
checks, downloads and checksum-verifies the runner, registers it with the org,
and installs a launchd service that survives reboots.

Two runners on one host, with extra labels:

```bash
./bootstrap.sh --count 2 --labels sonoma,xcode-16
```

## What you need first

- macOS 13+ (Sonoma / Sequoia), Intel `x64` or Apple `arm64` — the installer
  detects the architecture and picks the matching runner build.
- Xcode Command Line Tools: `xcode-select --install`
- A GitHub token that may manage org runners:
  - classic PAT with the **`admin:org`** scope, or
  - fine-grained PAT with the org permission **Self-hosted runners: Read and write**.

  Store it in `.env` as `GITHUB_PAT`. It is used *only* to mint short-lived
  registration tokens and is never written into the runner directory. A `gh auth
  login` token works too, but only if that login carries `admin:org` — the
  default `gh` scopes do not.

## Commands

| Command | What it does |
| --- | --- |
| `./bootstrap.sh` | First-time setup on a fresh VM |
| `make install` | Install/start runners (`ARGS="--count 2"`) |
| `make status` | Local launchd state plus the org's view |
| `make doctor` | Preflight: tooling, token, sleep, auto-login |
| `make update` | Update runner binaries in place |
| `make uninstall` | Stop, deregister and delete runners |
| `make logs` | Tail `_diag` logs |
| `make check` | Shellcheck + unit tests |

Every script also takes `--help`.

## Configuration

Copy `.env.example` to `.env` (`chmod 600`) and edit. Anything in `.env` can be
overridden by a flag on `bin/install.sh`.

| Variable | Default | Notes |
| --- | --- | --- |
| `GITHUB_ORG` | `quavon-dev` | Org the runners register with |
| `GITHUB_PAT` | — | `admin:org` token; falls back to `gh auth token` |
| `RUNNER_LABELS` | — | Extra labels; `macOS`, the arch and `macos-<major>` are added automatically |
| `RUNNER_GROUP` | `Default` | Runner group |
| `RUNNER_COUNT` | `1` | Runners per host |
| `RUNNER_NAME_PREFIX` | short hostname | With `count > 1`, names get `-1`, `-2`, … |
| `RUNNER_BASE_DIR` | `~/actions-runners` | Install location |
| `RUNNER_VERSION` | `latest` | Or pin, e.g. `2.337.0` |
| `RUNNER_EPHEMERAL` | `false` | One job per registration (see below) |

## Using the runners in a workflow

```yaml
jobs:
  build:
    runs-on: [self-hosted, macOS, x64]
    steps:
      - uses: actions/checkout@v5
      - run: sw_vers && xcodebuild -version
```

Pin harder with your own labels, e.g. `[self-hosted, macOS, x64, sonoma]`.

## Persistent vs ephemeral

**Persistent** (default) — one long-lived runner process picks up job after job.
Fastest start-up; workspace state carries over between jobs, so a job can be
polluted by its predecessor.

**Ephemeral** (`RUNNER_EPHEMERAL=true` or `--ephemeral`) — each job gets a
freshly registered runner that is discarded afterwards. `bin/run-ephemeral.sh`
registers, takes exactly one job, deregisters, and exits; launchd restarts it.
Slower per job, much better isolation. Recommended if workflows from many repos
share a host.

## Security notes

- `.env` holds a token. It is `chmod 600`, git-ignored, and `doctor` fails if the
  mode is wrong.
- Self-hosted runners must **not** be used on public repos: a fork PR can run
  arbitrary code on the VM. Keep them on private repos, or gate with
  environments and required reviewers.
- Nothing here needs `sudo`. The service is a launchd *user agent* under your own
  account, so a compromised job cannot trivially escalate to root.
- The runner tarball is verified against the SHA-256 published in the
  `actions/runner` release notes before it is unpacked.

## Multiple VMs

Every VM runs the same two commands (`git clone`, `./bootstrap.sh`). Names come
from the hostname, so give each VM a distinct one before bootstrapping:

```bash
sudo scutil --set HostName quavon-mac-02
sudo scutil --set LocalHostName quavon-mac-02
sudo scutil --set ComputerName quavon-mac-02
```

See [docs/vm-setup.md](docs/vm-setup.md) for the full VM checklist (auto-login,
sleep, cloning an image) and [docs/troubleshooting.md](docs/troubleshooting.md)
when something misbehaves.
