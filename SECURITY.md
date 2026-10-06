# Security

Lumina is a guest of macOS. The agent holds an Accessibility grant so it can read and move windows. That grant is the sensitive part of the project.

## Reporting

Please use [GitHub private vulnerability reporting](https://github.com/Zelmari/lumina/security/advisories/new) rather than a public issue. That page accepts reports only after private vulnerability reporting is turned on in the repository settings.

Include the macOS version, the Lumina commit, and what an attacker can do. Do not paste Accessibility dumps, window titles, or the contents of `~/Library/Logs/Lumina.log` unless you have removed anything private. Those logs name apps and windows.

## What a report is not

A window that overlaps, a hotkey that goes dead while Secure Input is on, or Stage Manager fighting the layout is a bug. Use the public bug template for those.

## Scope

The agent accepts commands on a Unix socket bound to the current user. It is not a network service. Patches that listen on a network interface, weaken the peer-uid check, or disable library validation will not be accepted.
