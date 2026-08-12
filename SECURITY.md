# Security policy

## Supported versions

Only the latest release and the `main` branch receive fixes.

## Reporting

Please use GitHub private vulnerability reporting. Do not open a public issue
containing credentials, private driver archives, host inventory, or VM disks.

## Secret handling

This project does not need passwords, tokens, cookies, or SSH private keys.
Never attach these files to an issue:

- `.env`, `rclone.conf`, certificates, SSH keys
- exported NVIDIA/WSL driver archives
- VM disks or complete system logs

Before posting logs, remove usernames, public IP addresses, domain names and VM
paths when they are sensitive in your environment.
