# Security policy

## Supported versions

Only the latest commit on `main` is supported.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private reporting: **Security** tab, then **Report a vulnerability**.

Include what you found, how to reproduce it, and what it could do. You will get a reply within a week.

## In scope

`install.sh` runs with `sudo` and downloads vendor installers, so these matter most: command injection through flags or environment variables, unverified downloads, writes outside `$HOME` that the plan did not list, and anything that deletes a path the user owns without a backup.

Vulnerabilities in a vendor's own installer or package belong with that vendor.
