# Contributing

Thanks for helping. This repo is GNU Stow dotfiles plus one installer, `install.sh`, for Arch, Debian and Ubuntu.

## Before you open a PR

- Open an issue first for anything large (a new config, a new flag, a new distro branch).
- Read the README sections on the installer. The conventions that matter most: one dispatcher function per distro difference, never a second literal Debian list (use `strip_items`), and nothing may change the machine before the plan is confirmed.

## Check your change

```bash
.github/lint.sh      # shellcheck, needs shellcheck on PATH
bash tests/run.sh    # offline suite, stubbed package managers
```

Both must pass. CI runs them on bash 5.1 and 5.2, then a real install on Arch, Omarchy, Debian 12/13 and Ubuntu 24.04/26.04.

## Adding a config or app

Follow "Adding a new config" in the README: a folder named after the app, mirroring the stow target, then entries in the arrays and maps in `install.sh`. A new app also needs a description and a group so it appears in the menu.

## Bug reports

Run `bash doctor.sh` and paste the output into the issue. It is read-only.

## Commits

Small, themed commits with a message that says why. Do not push to `main` directly; open a PR.
