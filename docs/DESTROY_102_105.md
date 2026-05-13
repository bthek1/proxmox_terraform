# Destroy Plan: Remove Containers 102 (nextcloud) and 105 (x-n8n)

**Date:** 2026-04-29  
**Scope:** Permanently delete LXC containers 102 and 105 from Proxmox node `bthek1`  
**Method:** Direct Proxmox CLI — neither container is tracked in Terraform state

> **WARNING: This is irreversible. All data inside these containers will be lost.**

---

## Pre-flight Checks

Before destroying, confirm the containers exist and note their status:

```bash
ssh proxmox
# On the Proxmox host (as root):
pct list
```

Expected entries:
| VMID | Name       | Status  |
|------|------------|---------|
| 102  | nextcloud  | running / stopped |
| 105  | x-n8n      | running / stopped |

---

## Step 1 — Backup (Optional but Recommended)

If you want a final snapshot before deletion:

```bash
# On Proxmox host (as root):
vzdump 102 --storage local --compress zstd --mode stop
vzdump 105 --storage local --compress zstd --mode stop
```

Verify backups exist:
```bash
ls /var/lib/vz/dump/ | grep -E "vzdump-lxc-10[25]-"
```

---

## Step 2 — Stop the Containers

Containers must be stopped before they can be destroyed.

```bash
# On Proxmox host (as root):
pct stop 102
pct stop 105
```

Verify both are stopped:
```bash
pct status 102   # → status: stopped
pct status 105   # → status: stopped
```

If a container is unresponsive, force-stop:
```bash
pct stop 102 --skiplock 1
pct stop 105 --skiplock 1
```

---

## Step 3 — Destroy the Containers

This deletes the container config and all associated disk volumes:

```bash
# On Proxmox host (as root):
pct destroy 102 --purge
pct destroy 105 --purge
```

The `--purge` flag removes all disk images from storage in addition to the config.

---

## Step 4 — Verify Removal

Confirm the containers are gone:

```bash
pct list
# 102 and 105 should no longer appear
```

Check storage has been freed:
```bash
lvs | grep -E "vm-10[25]"   # for LVM-based storage
# or
ls /var/lib/vz/images/ | grep -E "10[25]"  # for dir-based storage
```

---

## Step 5 — Cleanup (if applicable)

### DNS / Static IP reservations
If 102 or 105 had static IPs assigned in your router/DHCP server, remove those reservations.

### Firewall rules
If Proxmox firewall rules reference these containers:
```bash
# Check for container-level rules
cat /etc/pve/firewall/102.fw 2>/dev/null
cat /etc/pve/firewall/105.fw 2>/dev/null
# They will be auto-removed when the container is purged,
# but verify nothing remains in the cluster firewall:
cat /etc/pve/firewall/cluster.fw | grep -E "10[25]"
```

### External data (if Nextcloud used bind mounts or NFS)
If container 102 (Nextcloud) had external bind mounts (e.g., `/mnt/data`), those host-side directories are **not** removed by `pct destroy`. Clean up manually if desired:
```bash
# Example — adjust path to match actual mount:
rm -rf /mnt/nextcloud-data   # ONLY if safe to delete
```

---

## Execution Checklist

- [ ] Confirmed containers 102 and 105 exist on Proxmox
- [ ] Decided on backup (yes/no)
- [ ] Backup completed (if yes)
- [ ] Container 102 stopped
- [ ] Container 105 stopped
- [ ] Container 102 destroyed (`pct destroy 102 --purge`)
- [ ] Container 105 destroyed (`pct destroy 105 --purge`)
- [ ] `pct list` confirms both are gone
- [ ] Storage verified clean
- [ ] DHCP/DNS reservations removed (if applicable)
- [ ] External bind-mount data cleaned up (if applicable)

---

## Notes

- Neither 102 nor 105 is tracked in the Terraform state at `terraform/lxc/terraform.tfstate` — no Terraform commands are needed.
- The active Terraform-managed container is **108** — do not touch it.
