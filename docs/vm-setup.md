# macOS VM checklist

Everything here is done once per VM, before or right after `./bootstrap.sh`.
None of it is required for a quick test, but a runner that sleeps, logs out, or
shares a hostname with another VM will fail in confusing ways.

## 1. Give the VM a unique name

Runner names are derived from the short hostname, and GitHub rejects duplicates
(the installer passes `--replace`, so a duplicate silently steals the other
VM's registration).

```bash
sudo scutil --set HostName quavon-mac-02
sudo scutil --set LocalHostName quavon-mac-02
sudo scutil --set ComputerName quavon-mac-02
```

Alternatively set `RUNNER_NAME_PREFIX` in `.env`.

## 2. Enable automatic login

The runner service is a launchd **user agent**: it only runs while the user is
logged in to a GUI session. On a headless VM that means auto-login.

System Settings → Users & Groups → Automatic login → select the runner user.

FileVault blocks auto-login. Either disable FileVault on the VM (fine when the
host disk is encrypted) or use `sudo defaults write /Library/Preferences/com.apple.loginwindow DisableFDEAutoLogin -bool false`
and keep the VM behind the host's disk encryption.

Verify:

```bash
defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser
```

## 3. Stop the machine from sleeping

```bash
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 autopoweroff 0
sudo pmset -a disablesleep 1     # laptops / lid-closed VMs
```

Also turn off "Lock screen after inactivity" — a locked screen keeps the agent
running, but screen-recording or UI tests will fail.

## 4. Xcode and the toolchain

```bash
xcode-select --install
# Full Xcode, if the workflows build apps:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

Optional shared tooling:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install git jq shellcheck
```

## 5. Bootstrap the runner

```bash
git clone https://github.com/quavon-dev/quavon-runners-macos.git ~/quavon-runners-macos
cd ~/quavon-runners-macos
./bootstrap.sh
make status
```

## 6. Verify it reboots cleanly

```bash
sudo reboot
# after login:
cd ~/quavon-runners-macos && make status
```

The runner should show `running` locally and `online` in the org listing.

## Cloning a VM image

Cloning a configured VM copies its runner registration, which two machines
cannot share. Before taking the image:

```bash
cd ~/quavon-runners-macos
make uninstall ARGS=--all   # deregisters and removes the runner
```

Keep `.env` in the image if the whole fleet shares one org token, then on each
clone:

```bash
sudo scutil --set HostName quavon-mac-0N   # and LocalHostName / ComputerName
cd ~/quavon-runners-macos && ./bootstrap.sh
```

## Scaling up

- One runner per VM is the cleanest split.
- Several runners on one big host: `./bootstrap.sh --count 4`. Stay at or below
  the physical core count; concurrent Xcode builds are I/O and RAM hungry.
- Mixing architectures is fine — the `x64` and `arm64` labels are applied
  automatically, so workflows can target either.
