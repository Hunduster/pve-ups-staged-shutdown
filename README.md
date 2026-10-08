# Proxmox staged UPS shutdown with NUT, PVE-UPS and QNAP

A reference implementation for safely shutting down a **single-node Proxmox VE environment where multiple VMs and LXC containers depend on storage provided by a NAS**.

The key problem is shutdown ordering:

**NAS-dependent guests must stop before the NAS, and the NAS must stop before the Proxmox host because the Proxmox host also provides its NUT/UPS status.**

A useful side effect is that shutting down the NAS also removes one of the largest loads from the UPS before the final hypervisor shutdown.

This project combines:

- **NUT** for the USB-connected UPS and UPS status distribution
- **NUT `upssched`** for a delayed first shutdown stage
- **Proxmox tags** for dynamically identifying guests that should be stopped early
- **QNAP's NUT client** for the NAS shutdown
- **PVE-UPS** for monitoring, safety thresholds, webhooks and the final Proxmox host shutdown
- **Proxmox VE** for the final shutdown ordering of the remaining guests

The resulting shutdown sequence is:

```text
Power failure
    │
    ├─ 0–10 min  │ Ride through short outages
    │
    ├─ 10 min    │ Gracefully stop `ups-aware` guests
    │            │ (primarily NAS/NFS-dependent workloads)
    │
    ├─ 15 min    │ NAS shuts down while NUT is still available
    │            │ → major UPS load disappears
    │
    └─ 20 min    │ PVE-UPS shuts down Proxmox
```

The timings are intentionally conservative and specific to this setup.

**The architecture and dependency order are the important parts, not the exact numbers.**

> [!IMPORTANT]
> This is an opinionated reference implementation, not a universal recipe.
>
> Adapt timings, battery thresholds, firewall rules, storage dependencies and Proxmox shutdown ordering to your own environment.

---

## The problem this solves

The NAS in this setup is not just another device connected to the UPS.

It provides NFS storage to multiple VMs and LXC containers running on the Proxmox host. Some guests actively read from and write to these mounts during normal operation.

This creates the first shutdown dependency:

**The NAS must remain available until its dependent guests have stopped.**

Shutting down the NAS too early would reduce UPS load, but it could also make NFS storage disappear underneath running applications. Depending on the workload, this can result in I/O errors, hung processes, interrupted writes or application data corruption.

There is also a second dependency in the opposite direction:

**The NUT server itself runs on the Proxmox host.**

The NAS is configured as a network UPS client and receives its UPS state from that NUT server. If the Proxmox host shuts down first, the NUT server disappears with it.

A lost connection to the NUT server must not be treated as a reliable substitute for an actual UPS shutdown event. The NAS therefore needs to complete its own UPS-triggered shutdown **while the Proxmox host and its NUT server are still running**.

This creates a dependency chain:

```text
NAS-dependent guests
        │
        │ need NFS
        ▼
       NAS
        │
        │ needs NUT status
        ▼
NUT / Proxmox host
```

The shutdown sequence therefore has to respect this order:

```text
storage clients → storage server → NUT server / hypervisor
```

There is also a useful secondary benefit: in this environment, the NAS is one of the largest loads on the UPS. Shutting it down before the hypervisor significantly reduces UPS load and leaves more battery reserve for the final Proxmox shutdown.

The solution is a staged shutdown:

```text
Power outage
     │
     ├─ 0–10 min  → keep everything running
     │
     ├─ 10 min    → gracefully stop NAS-dependent guests
     │
     ├─ 15 min    → NAS shuts down while NUT is still available
     │
     └─ 20 min    → PVE-UPS shuts down the Proxmox host
```

This gives NAS-dependent guests five minutes to shut down while their storage is still available.

The NAS then has another five minutes to perform its own shutdown while the NUT server on the Proxmox host is still alive.

Only after both dependency stages have had time to complete does PVE-UPS request the final hypervisor shutdown.

That dependency ordering is the main idea behind this repository.

---

## Why not just let Proxmox shut everything down?

A normal Proxmox host shutdown already shuts down its guests before powering off the host.

That alone is not sufficient in this setup because the NAS is external to Proxmox and uses the Proxmox host itself as its NUT server.

If Proxmox shuts down before the NAS:

1. the NUT server disappears,
2. the NAS loses its UPS status source,
3. the NAS can no longer rely on that NUT server to complete the intended delayed UPS shutdown.

The NAS therefore has to shut down **before the Proxmox host**, but it cannot shut down before the guests that depend on its NFS exports.

This creates the central ordering problem solved by Stage 1:

```text
NAS-dependent guests
        │
        ▼
       NAS
        │
        ▼
NUT server / Proxmox host
```

Stage 1 solves the first dependency by stopping NAS clients early.

The NAS's own UPS timer solves the second dependency by shutting the NAS down while NUT is still alive.

PVE-UPS then performs the final Proxmox shutdown only after both stages have had time to complete.

This ordering also has the useful side effect of removing the NAS, one of the largest UPS loads in this environment, before the final hypervisor shutdown.

---

## Why combine NUT and PVE-UPS?

A USB UPS still needs something to communicate with the hardware.

NUT runs directly on the Proxmox host and talks to the UPS using `usbhid-ups` or another appropriate NUT driver.

It then exposes the UPS state over TCP/3493 to multiple consumers:

```text
                         USB UPS
                            │
                            ▼
                     NUT on Proxmox
                            │
                 ┌──────────┴──────────┐
                 │                     │
                 ▼                     ▼
              QNAP NAS              PVE-UPS
```

PVE-UPS then adds the parts that are more convenient to manage centrally:

- web interface
- UPS status
- configurable shutdown thresholds
- dry-run testing
- webhooks
- Proxmox API integration
- final Proxmox host shutdown

PVE-UPS supports a NUT server as a read-only source for USB/serial UPS devices.

NUT's `upssched` is retained for one additional task specific to this setup:

**after ten continuous minutes on battery, execute Stage 1 and gracefully stop guests carrying the `ups-aware` tag.**

### Responsibilities at a glance

| Component | Responsibility |
|---|---|
| NUT | Communicate with the USB UPS and distribute UPS status |
| `upsmon` | Detect UPS state changes |
| `upssched` | Maintain the 10-minute Stage-1 timer |
| `ups-stage1.sh` | Gracefully shut down tagged Proxmox guests |
| NAS / QNAP | Perform its own delayed shutdown |
| PVE-UPS | Monitor UPS policy, safety thresholds, webhooks and final PVE shutdown |
| Proxmox VE | Shut down remaining guests in the configured order |
| Home Assistant | Optional notification delivery |

> [!IMPORTANT]
> This design intentionally has **one authority for the final hypervisor shutdown: PVE-UPS**.
>
> NUT still monitors the UPS and drives Stage 1, but its own host shutdown command is suppressed.
>
> Running two independent host-shutdown policies in parallel would make the final shutdown timing harder to predict.

---

## Design goals

This implementation was built around the following priorities:

- Ride through short outages without shutting anything down.
- Prioritize data integrity over maximum battery runtime.
- Keep NFS available until dependent guests have had time to stop.
- Shut down NAS-dependent guests before the NAS.
- Remove the large NAS load before the hypervisor finally shuts down.
- Never hard-stop a Stage-1 guest automatically.
- Avoid static VMID lists.
- Make adding new dependent guests a simple Proxmox tagging operation.
- Keep the host-side scripts generic and independent of Home Assistant.
- Have exactly one authority for the final host shutdown: **PVE-UPS**.

---

## Repository layout

```text
.
├── README.md
├── LICENSE
├── SECURITY.md
├── docs/
│   └── ARCHITECTURE.md
├── scripts/
│   ├── nut-event-handler.sh
│   └── ups-stage1.sh
├── nut/
│   ├── nut.conf
│   ├── ups.conf
│   ├── upsd.conf
│   ├── upsd.users.example
│   ├── upsmon.conf.example
│   ├── upssched.conf
│   └── upssched-cmd
└── home-assistant/
    └── pve-ups-webhook.yaml
```

---

# Setup

## 1. NUT on the Proxmox host

Install and configure NUT as a network server and connect the UPS using `usbhid-ups` or the appropriate driver for your UPS.

The examples in [`nut/`](nut/) assume the UPS is named:

```text
qnapups
```

This also matches the compatibility requirements used by QNAP.

Copy and adapt the example configuration files, then ensure permissions are appropriately restrictive.

In the tested setup:

```text
NUT configuration files: 0640
Executable scripts:       0750
```

Do **not** blindly copy `upsd.users.example`.

Replace the example local monitor password before using it.

### NUT is not responsible for the final host shutdown

The included `upsmon.conf.example` deliberately uses a harmless logger as `SHUTDOWNCMD`.

NUT remains responsible for:

```text
UPS communication
        │
        ├─ status → NAS
        ├─ status → PVE-UPS
        │
        └─ ONBATT / ONLINE events
                   │
                   ▼
                upssched
                   │
                   ▼
                Stage 1
```

The final Proxmox host shutdown belongs exclusively to PVE-UPS.

---

## 2. Stage 1: tag-based guest shutdown

Install the scripts:

```bash
install -m 0750 scripts/nut-event-handler.sh /usr/local/sbin/nut-event-handler.sh
install -m 0750 scripts/ups-stage1.sh /usr/local/sbin/ups-stage1.sh
install -m 0750 nut/upssched-cmd /etc/nut/upssched-cmd
```

Adapt/copy `nut/upssched.conf` and point `upsmon`'s `NOTIFYCMD` to:

```text
/usr/local/sbin/nut-event-handler.sh
```

NUT's `upssched` is used to implement the delay:

```text
ONBATT
   │
   └─ START-TIMER ups-stage1 600
                    │
                    ├─ ONLINE before expiry
                    │      └─ cancel timer
                    │
                    └─ 600 seconds elapsed
                           │
                           ▼
                    execute Stage 1
```

This means a short power outage does not shut anything down.

---

## Why the `ups-aware` tag?

A simple implementation could contain a static list of VMIDs:

```bash
qm shutdown 123
pct shutdown 200
pct shutdown 201
```

That works, but it creates an easy-to-forget maintenance task.

Every new guest using an NFS mount would also have to be added manually to the UPS shutdown script.

Recreating a guest with a different VMID could silently break the intended shutdown dependency.

Instead, **Proxmox tags are used as the source of truth**.

Any guest that should be stopped during Stage 1 receives the tag:

```text
ups-aware
```

The shutdown script discovers matching guests dynamically every time it runs.

Typical examples:

| Workload | NAS dependency | `ups-aware` |
|---|---:|---:|
| Media server with NFS media mount | Yes | Yes |
| Download service writing to NAS | Yes | Yes |
| Backup VM writing to NAS | Yes | Yes |
| Home Assistant | No | No |
| Router / firewall | No | No |

The operational workflow for a new NAS-dependent guest therefore becomes:

```text
Create guest
    │
Configure NAS/NFS mount
    │
Add `ups-aware` tag
    │
Done
```

No VMID list and no script modification are required.

Although `ups-aware` is primarily used here for NAS-dependent guests, the tag is intentionally generic.

It can also be applied to other workloads that should be stopped during Stage 1, for example:

- non-critical workloads
- high-power workloads
- services that are not required during an extended outage

---

## Stage-1 safety behavior

Stage 1 handles both:

- QEMU virtual machines
- LXC containers

Only guests that are both:

1. tagged `ups-aware`
2. currently running

are considered.

Shutdown requests are issued in parallel.

Each guest receives up to five minutes for a graceful shutdown.

There is deliberately **no automatic hard-stop fallback**.

The scripts never automatically use:

```bash
qm stop
pct stop
```

If a guest does not stop within the configured timeout, the failure is logged but the guest is not forcibly terminated.

This is intentional: **data integrity has priority over forcing the shutdown sequence to complete.**

---

## Stage-1 dry-run

Before enabling the timer, verify which guests would be affected:

```bash
/usr/local/sbin/ups-stage1.sh --dry-run
```

Example:

```text
Stage 1 started. Mode=dry-run; tag=ups-aware; timeout=300s.
LXC 200 (media): running, WOULD request graceful shutdown.
QEMU 300 (backup): running, WOULD request graceful shutdown.
Stage 1 dispatch complete. Tagged=2; running candidates=2.
```

This command does not shut anything down.

---

## Execute Stage 1 manually

> [!WARNING]
> This command really shuts down all currently running guests tagged `ups-aware`.

```bash
/usr/local/sbin/ups-stage1.sh --execute
```

Shutdown requests run in parallel with a five-minute graceful timeout.

---

## 3. NAS / QNAP

This reference implementation uses a **QNAP NAS** configured as a NUT network UPS slave/client.

The NAS connects to the NUT server running on the Proxmox host.

For this reference design:

```text
NAS shutdown after: 15 minutes on battery
```

This gives Stage 1:

```text
10 min → Stage 1 begins
15 min → NAS shutdown begins
```

or five minutes for storage-dependent guests to stop while their NFS mounts are still available.

### QNAP compatibility values

PVE-UPS documents the QNAP compatibility values as:

```text
UPS name: qnapups
User:     admin
Password: 123456
```

These are vendor compatibility values, not a private password from this repository.

Nevertheless, access to NUT TCP/3493 should be restricted to trusted systems.

> [!NOTE]
> QNAP is the NAS used by this reference implementation.
>
> The staged design itself is not inherently QNAP-specific. The same dependency model can be used with another NAS or storage system if it can perform its own delayed shutdown based on UPS state.
>
> Other NAS platforms have not been tested by this repository unless explicitly stated.

---

## 4. PVE-UPS

Install PVE-UPS using the project's documented installer or its Community Scripts entry.

An unprivileged LXC on trusted/local storage is a good fit for this design.

Configure the UPS source as NUT:

```text
Host:     <NUT server address>
Port:     3493
UPS name: qnapups
```

For a USB UPS, PVE-UPS does **not** need USB passthrough.

The physical UPS remains attached to the Proxmox host and PVE-UPS reads its status through NUT.

---

## Proxmox API token

Use a dedicated Proxmox user/API token.

The token only needs the power-management privilege on the protected node:

```text
Sys.PowerMgmt
```

Avoid giving PVE-UPS full administrator permissions.

Do not commit:

- API token secrets
- real API credentials
- private management addresses unless intentionally public

---

## Reference PVE-UPS thresholds

The tested policy uses:

```text
On battery longer than: 1200 s
Runtime below:          15 min
Charge below:           25 %
LOWBATT/depleted:       immediate

Poll interval on mains: 30 s
Poll interval battery:   8 s
Re-arm after mains:       5 min
```

The normal shutdown path is:

```text
20 minutes continuously on battery
```

The runtime, charge and LOWBATT thresholds are safety nets.

For example, if battery runtime drops below 15 minutes before the 20-minute timer expires, PVE-UPS can initiate the final shutdown earlier.

---

## Dry-run before ARMED

Keep PVE-UPS in:

```text
DRY-RUN
```

until all of the following have been validated:

- NUT reads the UPS correctly
- NAS can read the NUT server
- PVE-UPS can read the NUT server
- Proxmox API credentials work
- `Sys.PowerMgmt` is available
- Stage-1 tag selection is correct
- Stage-1 shutdown has been tested
- notifications/webhooks work
- production thresholds are restored

Only then switch PVE-UPS to:

```text
ARMED
```

> [!WARNING]
> In ARMED mode, a matching trigger can cause a real shutdown of the Proxmox host and all remaining guests.

---

## 5. Home Assistant / webhooks (optional)

PVE-UPS can send JSON webhooks for UPS events.

The example in:

[`home-assistant/pve-ups-webhook.yaml`](home-assistant/pve-ups-webhook.yaml)

shows one way to convert these events into human-friendly notifications.

Replace:

```text
REPLACE_WITH_RANDOM_WEBHOOK_ID
script.REPLACE_WITH_NOTIFICATION_SCRIPT
```

with your own values.

Do not commit the real webhook ID.

The host-side NUT and Stage-1 scripts deliberately have **no Home Assistant dependency**.

Notifications are considered a convenience feature and are not part of the shutdown safety chain.

Example notification flow:

```text
PVE-UPS
   │
   │ JSON webhook
   ▼
Home Assistant
   │
   ▼
Notification service
```

The tested environment uses Pushover as the final notification service.

---

## 6. Power return behavior

### Power returns before Stage 1

If utility power returns before ten minutes:

```text
ONBATT
   │
   └─ 600-second timer
           │
           ▼
        ONLINE
           │
           └─ CANCEL-TIMER
```

Nothing is shut down.

---

### Power returns after Stage 1

If Stage 1 has already executed, this reference implementation does **not** automatically restart the stopped guests.

Manual restart after utility power has remained stable is intentional.

This avoids immediately restarting workloads during unstable or repeatedly failing utility power.

---

## 7. Proxmox guest shutdown order

The final host shutdown is handed back to Proxmox itself.

Configure Proxmox startup/shutdown ordering for infrastructure guests that must remain available late in the shutdown sequence.

Typical examples include:

- router/firewall VMs
- DNS
- management services
- notification infrastructure

Proxmox reverses the configured startup order during shutdown.

The repository intentionally does not hard-code VMIDs for infrastructure guests.

The Stage-1 script only cares about the `ups-aware` tag.

---

# Testing and validation

## Useful checks

### UPS state

```bash
upsc qnapups@localhost
```

### NUT services

```bash
systemctl status \
  nut-driver@qnapups.service \
  nut-server.service \
  nut-monitor.service
```

### Stage-1 selection

```bash
/usr/local/sbin/ups-stage1.sh --dry-run
```

### Stage-1 logs

```bash
journalctl -t ups-stage1
```

### NUT event logs

```bash
journalctl -t nut-event
```

### NUT server port

```bash
ss -lntp | grep ':3493'
```

---

## Recommended commissioning sequence

A safe commissioning sequence is:

1. Validate that NUT reads the UPS.
2. Validate that the NAS can read the NUT server.
3. Validate that PVE-UPS can read the NUT server.
4. Validate the Proxmox API token and `Sys.PowerMgmt`.
5. Add `ups-aware` only to disposable/test guests.
6. Run `ups-stage1.sh --dry-run`.
7. Run Stage 1 manually against the test guests.
8. Temporarily shorten the `upssched` timer for an end-to-end Stage-1 test.
9. Restore the production timer to 600 seconds.
10. Test a short real power outage.
11. Verify that `ONBATT → ONLINE` cancels Stage 1.
12. Test PVE-UPS in dry-run mode.
13. Test notification/webhook delivery.
14. Restore all production thresholds.
15. Only then switch PVE-UPS to ARMED.

> [!WARNING]
> Do not perform a full production host-shutdown test unless you are prepared for the Proxmox host, its guests and potentially network infrastructure to actually go down.

---

# Failure behavior

## A Stage-1 guest does not stop

The script waits up to the configured graceful timeout.

It does **not** issue a hard stop.

The failure is written to the journal.

Inspect with:

```bash
journalctl -t ups-stage1
```

---

## NUT communication fails

PVE-UPS and the NAS will no longer receive valid UPS state.

Do not configure a host shutdown solely because of a temporary communication failure unless that behavior is explicitly desired for your environment.

---

## PVE-UPS becomes unavailable

NUT continues to communicate with the physical UPS and Stage 1 can still operate.

However, the final Proxmox API shutdown is owned by PVE-UPS in this design.

Monitoring the PVE-UPS appliance itself is therefore recommended.

---

## NAS shuts down

Once the NAS has shut down, its NFS exports are no longer available.

That is why all guests depending on those exports must be included in Stage 1.

---

# Maintenance

## Adding a new NAS-dependent guest

When creating a new VM or LXC that depends on NAS storage:

1. configure the required mount/storage dependency,
2. add the Proxmox tag:

```text
ups-aware
```

3. verify selection:

```bash
/usr/local/sbin/ups-stage1.sh --dry-run
```

No script modification is necessary.

---

## After Proxmox or NUT upgrades

Check:

```bash
systemctl status \
  nut-driver@qnapups.service \
  nut-server.service \
  nut-monitor.service
```

Then verify:

```bash
upsc qnapups@localhost
```

and:

```bash
/usr/local/sbin/ups-stage1.sh --dry-run
```

---

## After PVE-UPS upgrades

Verify:

- NUT connection
- UPS status
- Proxmox API connection
- `Sys.PowerMgmt`
- protected host assignment
- thresholds
- DRY-RUN / ARMED state
- webhook configuration

Use the built-in test notification where appropriate.

---

# Security

See [`SECURITY.md`](SECURITY.md).

General recommendations:

- Keep NUT TCP/3493 restricted to trusted clients.
- Keep PVE-UPS on a trusted internal/management network.
- Use a dedicated Proxmox API token.
- Grant only `Sys.PowerMgmt` where possible.
- Never commit API token secrets.
- Never commit Home Assistant webhook IDs.
- Remove private addresses, hostnames and serial numbers before publishing logs.
- Review `git diff --cached` before every public commit containing configuration changes.

The QNAP compatibility password `123456` shown in this repository is a vendor-defined compatibility value and not a private credential from the reference environment.

---

# Troubleshooting

## Check current UPS values

```bash
upsc qnapups@localhost
```

Important fields include:

```text
ups.status
battery.charge
battery.runtime
battery.runtime.low
```

Common states:

```text
OL       = On Line
OB       = On Battery
OL CHRG  = On Line / charging
LB       = Low Battery
```

---

## Check which guests Stage 1 would stop

```bash
/usr/local/sbin/ups-stage1.sh --dry-run
```

This should be part of regular maintenance after changing tags or adding storage-dependent guests.

---

## Check Stage-1 execution

```bash
journalctl -t ups-stage1 --since "-1 hour" --no-pager
```

---

## Check UPS events

```bash
journalctl -t nut-event --since "-1 hour" --no-pager
```

---

## Check NUT monitor

```bash
journalctl -u nut-monitor.service --since "-1 hour" --no-pager
```

---

# Tested reference scenario

This repository was developed around the following general environment:

```text
Single Proxmox VE node
        │
        ├─ USB-connected APC UPS
        │
        ├─ NUT running on the PVE host
        │
        ├─ multiple VMs/LXCs
        │      └─ several with NAS/NFS dependencies
        │
        └─ PVE-UPS running as an unprivileged LXC

NAS
        │
        ├─ NUT network UPS client
        ├─ provides NFS storage to Proxmox guests
        └─ significant share of total UPS load

Home Assistant
        │
        └─ receives optional PVE-UPS webhooks
```

The exact hardware, VMIDs, addresses and internal infrastructure details are intentionally not part of this repository.

---

# Upstream documentation

- PVE-UPS: https://github.com/ffind-dev/pve-ups
- Network UPS Tools: https://networkupstools.org/
- NUT `upssched`: https://networkupstools.org/docs/man/upssched.html
- Proxmox VE: https://pve.proxmox.com/

---

# License

MIT. See [`LICENSE`](LICENSE).

---

## Final note

This setup intentionally favors **predictable shutdown behavior and data integrity over maximum UPS runtime**.

The exact timers are only an example.

The reusable idea is the shutdown dependency:

```text
NAS/storage clients
        ↓
NAS/storage server
        ↓
remaining workloads
        ↓
hypervisor
```

Combined with PVE-UPS, NUT and Proxmox tags, this provides a relatively simple way to handle a storage-dependent homelab without maintaining static VMID lists or letting multiple tools compete for control of the final host shutdown.
