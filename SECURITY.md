# Security notes

This repository intentionally contains no private IP addresses, UPS serial numbers, Home Assistant webhook IDs, Proxmox API secrets, or environment-specific credentials.

Before publishing local changes, search for at least:

```bash
grep -RniE '(https?://|[0-9]{1,3}(\.[0-9]{1,3}){3}|token|secret|password|serial|webhook)' . \
  --exclude-dir=.git
```

The QNAP NUT compatibility credentials shown in the documentation (`admin` / `123456`, UPS name `qnapups`) are vendor-prescribed compatibility values documented by PVE-UPS/QNAP and are not a private secret for this example. Restrict TCP/3493 with network/firewall policy.

Never commit:
- Proxmox API token secrets
- Home Assistant webhook IDs/URLs
- public DNS names or private management addresses unless intentionally disclosed
- UPS serial numbers
- backups of `/etc/nut`
