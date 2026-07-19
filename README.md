# atlas

Luka's homelab / personal-cloud server — an NZXT box in the corner that does
the heavy lifting: GPU inference, audio analysis, remote builds, agents.

**This repo** is the home for the atlas CLI and every utility that runs *on*
atlas — language models (Ollama), speech-to-text (Whisper), the remote build
tooling, maintenance scripts. It lives at `~/atlas` on the server itself
(deliberately separate from `~/projects`, which holds the app repos).

## What is atlas?

| | |
|---|---|
| Machine | NZXT desktop, built into a headless server (July 2026) |
| CPU | Intel i7-12700K (20 threads) |
| RAM | 31 GB |
| GPU | NVIDIA RTX 4060 Ti 8 GB (+ Intel UHD 770 iGPU) |
| Disk | 936 GB NVMe |
| OS | Ubuntu Server 26.04 LTS ("resolute"), headless |
| User | `luka` (passwordless sudo) |

## Stack (installed & working)

- **NVIDIA driver 595.71.05** (open modules) + **CUDA 13.3** (`nvcc` in PATH)
- **Docker 29.6.2** + compose v5.3.1, NVIDIA Container Toolkit
  (`docker run --gpus all` sees the GPU, rootless works)
- **Tailscale** (tailnet `your-tailnet`, device isolated to Luka's devices)
- Dev essentials: build-essential, gcc 15.2, git 2.53, tmux, btop, uv

## The CLI (`cli/`)

Rust, zero dependencies, installed on the Mac via `cargo install --path cli`
(needs `~/.cargo/bin` on PATH):

```bash
atlas              # SSH into atlas (execs ssh — a real session)
atlas boot         # Wake-on-LAN + waits until SSH is reachable (LAN only)
atlas shutdown     # sudo poweroff + waits until the box is down
atlas restart      # reboot + waits for it to come back
atlas status       # up/down + route (LAN / tailnet)
atlas <cmd ...>    # run anything remotely: atlas nvidia-smi, atlas htop ...
```

## SSH from the Mac

```bash
ssh atlas          # resolves to atlas.your-tailnet.ts.net — works from anywhere
```

Key auth (`~/.ssh/id_ed25519`), Tailscale SSH interception is OFF — plain
sshd. LAN IP: `192.168.1.100` · tailnet IP: `100.x.y.z`.

## Power on / off

`atlas boot` / `atlas shutdown` (see CLI above). Without the CLI:

```bash
# ON — Wake-on-LAN magic packet (same LAN; NIC enp4s0, armed via wol.service):
python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);s.sendto(b"\xff"*6+bytes.fromhex("74563cb19b08")*16,("192.168.1.255",9))'

# ON from outside the LAN: FritzBox MyFRITZ web UI -> "Wake" button
# (Tailscale can't wake a powered-off box)

# OFF:
ssh atlas 'sudo poweroff'
```

## What runs on it right now

- `~/projects/` — working clones of the app repos:
  claimini, dairo-app, ephraim-app, lgka-app, lightshow, orin-app, receipt-ai
- **lightshow**: the Art-Net → Hue Entertainment bridge
  (`bridge/hue_stream.py`, started per session, not a service) and the GPU
  song-analysis env (`analyze/.venv`: torch cu124, librosa, Beat This!)
- **This repo** at `~/atlas`
- Base services: sshd, tailscaled, docker, wol.service

## Planned (the point of this repo)

- **Ollama** — local LLMs on the GPU
- **Whisper** — speech-to-text
- **Remote build CLI** — one command on the Mac, heavy Rust/compile jobs run
  on atlas (sccache-style)
- Maintenance & convenience scripts (health checks, wake/sleep helpers)
