# LXC 107 RTX 3060 GPU Setup Plan

**Machine**: LXC 107 (`proxmox_rag`) — Ubuntu 24.04.4 LTS  
**GPU**: NVIDIA GeForce RTX 3060 LHR (host PCI `01:00.0`, passed through via device node mount)  
**Goal**: Get GPU fully operational inside the container so the Ollama / Open-WebUI / RAG stack can run GPU-accelerated inference.

---

## Current State (2026-05-17)

| Component | Status |
|-----------|--------|
| Device nodes (`/dev/nvidia*`) | ✅ Passed through — all 5 nodes present |
| Host kernel driver | `595.71.05` (DKMS `.run` installer) |
| Container NVML userspace | ❌ `580.105.08` — **version mismatch** |
| `nvidia-smi` inside container | ❌ `Failed to initialize NVML: Driver/library version mismatch` |
| `nvidia-container-toolkit` | `1.19.0` installed; CDI config present but stale |
| Docker nvidia runtime | ✅ Configured |
| Ollama container | ❌ Stopped (exited — GPU broken) |
| Open-WebUI container | ❌ Stopped |
| AnythingLLM container | ❌ Stopped |
| RAG_test stack (Django+Celery) | Partial — DB running, GPU workers stopped |

**Root cause**: The 580.x userspace libraries were installed manually (not tracked by dpkg) and are no longer compatible with the host kernel module at 595.71.05. The NVML ABI requires an exact major.minor match.

---

## Phase 1: Fix NVIDIA Driver/Library Version Mismatch

**Status**: Not started

**Goal**: Replace the stale 580.x userspace libraries inside LXC 107 with ones that match the host kernel module version (595.71.05), so `nvidia-smi` works.

**Context**: The NVIDIA `.run` installer for 595.71.05 supports a `--no-kernel-module` flag that installs only userspace libraries (no kernel module compilation). This is the correct approach for LXC containers — the kernel module lives on the host.

**Deliverables**:

- [ ] Remove old manually-installed 580.x NVIDIA userspace libraries from the container
- [ ] Download `NVIDIA-Linux-x86_64-595.71.05.run` inside the container
- [ ] Install with `--no-kernel-module --silent` flags
- [ ] Verify `nvidia-smi` outputs RTX 3060 info without errors

**Steps**:

```bash
# SSH into LXC 107
ssh proxmox_rag

# Remove old 580.x libraries (manually installed, not tracked by dpkg)
# The libs live under /usr/lib/x86_64-linux-gnu/
sudo find /usr/lib/x86_64-linux-gnu -name "*nvidia*.so.580*" -delete
sudo find /usr/lib/x86_64-linux-gnu -name "*libcuda*.so.580*" -delete
sudo find /usr/lib/x86_64-linux-gnu -name "*libnv*.so.580*" -delete
# Remove old nvidia-smi and nvidia-persistenced if manually installed
sudo rm -f /usr/bin/nvidia-smi /usr/bin/nvidia-persistenced

# Download the matching installer (same version as host)
DRIVER_VER="595.71.05"
wget -q --show-progress \
  "https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VER}/NVIDIA-Linux-x86_64-${DRIVER_VER}.run" \
  -O /tmp/NVIDIA-Linux-x86_64-${DRIVER_VER}.run
chmod +x /tmp/NVIDIA-Linux-x86_64-${DRIVER_VER}.run

# Install userspace only (no kernel module)
sudo /tmp/NVIDIA-Linux-x86_64-${DRIVER_VER}.run \
  --no-kernel-module \
  --silent \
  --no-drm \
  --no-backup \
  --no-x-check \
  --no-nouveau-check

# Verify
nvidia-smi
```

**Tests**:

- [ ] `nvidia-smi` exits 0 and shows `NVIDIA GeForce RTX 3060`
- [ ] `nvidia-smi --query-gpu=driver_version --format=csv,noheader` returns `595.71.05`

**Stability Criteria**: `nvidia-smi` runs without errors inside the container.

**Notes**:

---

## Phase 2: Regenerate CDI Config & Verify Docker GPU Access

**Status**: Not started

**Goal**: Regenerate the nvidia-container-toolkit CDI specification so Docker can correctly reference the 595.x library paths, then confirm a GPU test container works.

**Context**: The CDI spec at `/etc/cdi/nvidia.yaml` (or similar) was generated when the 580.x libs were installed. It contains hardcoded paths to 580.x `.so` files. After the Phase 1 library replacement, regeneration is required.

**Deliverables**:

- [ ] Regenerate CDI config with `nvidia-ctk cdi generate`
- [ ] Confirm CDI spec references 595.x library paths
- [ ] Run a CUDA test container with `--gpus all` and verify GPU is visible

**Steps**:

```bash
# Regenerate CDI config
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# Inspect the new spec
grep "version\|driver" /etc/cdi/nvidia.yaml | head -5

# Test Docker GPU access
docker run --rm --gpus all \
  nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi
```

**Tests**:

- [ ] `nvidia-ctk cdi generate` exits 0
- [ ] `docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi` shows RTX 3060

**Stability Criteria**: Docker can schedule GPU workloads via the nvidia runtime.

**Notes**:

---

## Phase 3: Start Ollama with GPU

**Status**: Not started

**Goal**: Start the Ollama service with GPU access, pull at least one model, and confirm GPU VRAM is used during inference.

**Context**: There are two Ollama Docker containers in the history — `ollama` (the main service, `/bin/ollama serve`) and `ollama-init` (one-time model pull). Both have exited. A persistent compose file needs to be created or the existing one found.

**Deliverables**:

- [ ] Locate or create a `docker-compose.yml` for the Ollama service with GPU device mapping
- [ ] Start Ollama container with GPU access
- [ ] Pull a small model (e.g. `llama3.2:1b` or `phi3:mini`) to verify GPU inference
- [ ] Confirm `nvidia-smi` shows VRAM usage during inference

**Steps**:

```bash
cd /home/bthek1/RAG_test   # or wherever the Ollama compose lives

# If no compose for ollama, create one:
# cat > docker-compose.ollama.yml << 'EOF'
# services:
#   ollama:
#     image: ollama/ollama:latest
#     ports:
#       - "11434:11434"
#     volumes:
#       - ollama_data:/root/.ollama
#     deploy:
#       resources:
#         reservations:
#           devices:
#             - driver: nvidia
#               count: all
#               capabilities: [gpu]
# volumes:
#   ollama_data:
# EOF

docker compose -f docker-compose.ollama.yml up -d
docker exec ollama ollama pull phi3:mini
# While pulling/running, in another window:
nvidia-smi   # confirm VRAM usage
```

**Tests**:

- [ ] `docker exec ollama ollama list` shows at least one model
- [ ] `curl http://localhost:11434/api/generate -d '{"model":"phi3:mini","prompt":"hello"}'` returns a response
- [ ] `nvidia-smi` shows non-zero GPU memory usage while inference runs

**Stability Criteria**: Ollama serves inference requests using GPU (not CPU fallback).

**Notes**:

---

## Phase 4: Start Open-WebUI & RAG Stack

**Status**: Not started

**Goal**: Start Open-WebUI connected to Ollama and bring up the RAG_test Django/Celery stack with GPU workers, verifying end-to-end GPU-accelerated RAG functionality.

**Deliverables**:

- [ ] Start `open-webui` container pointing to Ollama at `http://ollama:11434`
- [ ] Verify Open-WebUI is accessible in browser and can chat using the local model
- [ ] Start `RAG_test` stack (`docker compose up -d`)
- [ ] Confirm GPU-enabled Celery workers start without CUDA errors

**Steps**:

```bash
# Start Open-WebUI (update OLLAMA_BASE_URL if needed)
docker start open-webui
# Or recreate with correct env:
# docker run -d --name open-webui \
#   -p 3000:8080 \
#   -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
#   --add-host=host.docker.internal:host-gateway \
#   ghcr.io/open-webui/open-webui:latest

# Start RAG_test stack
cd /home/bthek1/RAG_test
docker compose up -d

# Check GPU workers
docker compose logs celery_worker | tail -20
```

**Tests**:

- [ ] Open-WebUI accessible at `http://<host-ip>:3000`
- [ ] Chat with model via Open-WebUI succeeds
- [ ] `docker compose logs celery_worker` shows no CUDA/GPU errors
- [ ] `nvidia-smi` shows GPU memory in use when RAG query runs

**Stability Criteria**: Full RAG stack running with GPU-accelerated inference, no CUDA errors in logs.

**Notes**:

---

## Phase 5: Documentation

**Status**: Not started

**Goal**: Update `docs/107_GPU_PASSTHROUGH_SETUP.md` with the version mismatch diagnosis and fix procedure so future upgrades are handled correctly.

**Deliverables**:

- [ ] Add "Userspace Library Version Mismatch" section to `docs/107_GPU_PASSTHROUGH_SETUP.md`
- [ ] Document the `.run --no-kernel-module` procedure for container userspace-only installs
- [ ] Add notes about CDI regeneration after driver updates

**Stability Criteria**: Documentation accurately reflects the current setup and repair procedure.

**Notes**:
