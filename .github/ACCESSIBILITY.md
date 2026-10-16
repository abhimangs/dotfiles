# Accessibility

## Commitment

The installer should be usable without a mouse, without colour, and over a plain SSH session.

## Supported environments

Any terminal on Arch, Debian or Ubuntu, including headless servers and WSL.

## What is built in

- Keyboard-only menu. Where it cannot draw (no tty, a dumb terminal), a numbered menu takes over.
- `--no-color` and `--ascii` adapt the menu instead of dropping it.
- Every choice can be given as a flag (`--configs=`, `--tools=`, `--apps=`), so no screen is needed.
- Output is plain text that a screen reader can read in order.

## Known limitations

- The TUI menu redraws the screen, which some screen readers announce noisily. Use the flags or `TERM=dumb` for the numbered menu.
- The themes are Catppuccin Mocha, a dark palette. There is no light variant.

## Reporting a barrier

Open an issue with the "Bug report" template and mention accessibility.
