# Architecture and rationale

This repository documents a deliberately opinionated single-node Proxmox VE UPS design.

## The use case

The environment has:

- one Proxmox VE node;
- an APC USB UPS connected directly to that node;
- NUT on the Proxmox host because USB UPS data must also be available to network clients;
- a QNAP NAS acting as a NUT network UPS client;
- many VMs/LXCs consuming NFS exports from that NAS;
- PVE-UPS in an unprivileged LXC for GUI monitoring, thresholds, webhooks and the final Proxmox host shutdown.

The goal is **not maximum battery uptime**. The goal is to ride through short outages and then shut down in a data-safe order while plenty of battery reserve remains.

## Why the shutdown is staged

If the NAS shuts down before its NFS clients, applications can see I/O failures or lose in-flight writes. If the Proxmox host shuts down too early, the NAS remains a large UPS load for no useful reason. The chosen sequence is therefore:

```text
00:00  Utility power fails
        Everything keeps running

10:00  Stage 1
        Gracefully shut down all running guests tagged `ups-aware`

15:00  NAS
        QNAP's own network-UPS timer shuts the NAS down

20:00  Hypervisor
        PVE-UPS requests a controlled Proxmox host shutdown
```

PVE-UPS also has safety triggers for low runtime, low charge and LOWBATT/depleted, so the 20-minute timer is not blindly awaited when the battery depletes faster than expected.

## Responsibility boundaries

### NUT

NUT owns:
- USB communication with the UPS;
- TCP/3493 data service for trusted clients;
- ONBATT/ONLINE event handling;
- the 10-minute `ups-aware` guest stage.

NUT intentionally does **not** own the final host shutdown.

### PVE-UPS

PVE-UPS owns:
- GUI/status;
- shutdown thresholds;
- Home Assistant/webhook notifications;
- final Proxmox host shutdown via the Proxmox API.

PVE-UPS supports NUT as a read-only UPS source for USB/serial UPS devices and is intended to run on an internal management network. Its own documentation recommends marking the host running the appliance as “This host”.

### QNAP

The QNAP remains a normal NUT network UPS client. Its shutdown timer is intentionally independent of the custom Proxmox scripts.

## `ups-aware`

`ups-aware` is an operational tag, not a hard-coded VM list.

A new guest that must be stopped before the NAS only needs the Proxmox tag:

```text
ups-aware
```

The script discovers tagged QEMU and LXC guests dynamically from `/etc/pve`, checks whether they are running and sends graceful shutdown requests in parallel.

It never issues `qm stop` or `pct stop`.

## Network/firewall assumptions

- NUT TCP/3493 is reachable only by trusted clients such as PVE-UPS and the NAS.
- PVE-UPS can reach the Proxmox API on TCP/8006.
- PVE-UPS itself is not exposed to the internet.
- Home Assistant webhooks use a random webhook ID and stay local where possible.
