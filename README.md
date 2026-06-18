# nvidia-thermal-autotuner

Keep every NVIDIA GPU under a **target temperature**, 24/7, by continuously
autotuning its **power limit**.

Instead of setting a fixed power cap and hoping it's right, this daemon treats
**temperature as the only constraint**: it nudges each card's power limit *up*
when the card is cool and busy, and *down* when it gets hot — so every GPU
settles at the **maximum sustainable power it can hold at your target temp**, and
rediscovers that point automatically as conditions change (ambient, neighbouring
cards, fan curve, workload).

It's a single dependency-free Bash script driven by `nvidia-smi`.

## Why

A static power cap is always wrong somewhere:

- Too low and you throw away performance whenever the card has thermal headroom.
- Too high and the card cooks (or throttles) when airflow is poor.

The right cap depends on airflow, ambient temperature, and what the *other* cards
in the box are doing — all of which move around. A closed loop on temperature
handles all of it. This is especially useful for:

- **Multi-GPU rigs** where a middle/"sandwiched" card is airflow-starved while
  the edge cards run cool — each finds its own limit.
- **Servers whose fan curves don't recognize the GPU** (e.g. consumer cards in
  enterprise chassis) and under-cool it.
- **Mixed-GPU machines** — no need to hand-tune per model.
- Keeping a workstation **quiet and cool** without permanently capping it.

## How it works

Every `INTERVAL_S` seconds, for each managed GPU:

- **temp ≥ `TARGET_C`** → lower the power limit (step proportional to the
  overshoot, never below the card's hardware minimum).
- **temp ≤ `TARGET_C − HYSTERESIS_C`** and **util ≥ `MIN_UTIL`** → raise the
  power limit one step, up to the card's hardware maximum.
- otherwise → hold.

The `MIN_UTIL` gate means an idle card's cool reading never triggers a raise
(an idle temperature tells you nothing about the loaded thermal limit) — a card
is tuned as soon as real load arrives. GPUs are addressed by **UUID**, so the
controller is unaffected by `nvidia-smi` index reshuffling when cards are added
or removed. Per-card hardware min/max are read from the driver, so it adapts to
any card.

**Mobile/laptop GPUs** frequently report no settable power limit. For those the
daemon runs the identical loop on a different lever — it autotunes the card's **max
SM clock** (`nvidia-smi -lgc`) instead of the power limit, lowering the clock cap
when hot and raising it when cool — so a laptop card also settles at the hottest
clock it can sustain at your target temp.

## Requirements

- Linux with `nvidia-smi` (NVIDIA proprietary driver).
- Privilege to change power limits (run as root / via the systemd unit).
- GPUs with a settable **power limit** (most desktop/server cards) — or, for GPUs
  without one (many **mobile/laptop** cards), a lockable **clock range**, which the
  daemon uses as an automatic fallback. Cards exposing neither are skipped.

## Install

```sh
git clone https://github.com/frstrtr/nvidia-thermal-autotuner.git
cd nvidia-thermal-autotuner
sudo ./install.sh
```

This installs the script to `/usr/local/bin`, installs and starts the systemd
service, and enables it at boot. Watch it work:

```sh
journalctl -u nvidia-thermal-autotuner -f
```

### Try it without changing anything

```sh
sudo DRY_RUN=1 TARGET_C=75 ./nvidia-thermal-autotuner.sh
```

Logs the decisions it *would* make without touching any power limit.

## Configuration

All via environment variables (set them in the systemd unit with
`Environment=KEY=VALUE`, then `systemctl daemon-reload && systemctl restart`):

| Variable       | Default | Meaning |
|----------------|:-------:|---------|
| `TARGET_C`     | `80`    | Target ceiling temperature (°C). Power is reduced at/above this. |
| `HYSTERESIS_C` | `5`     | Only raise when `temp ≤ TARGET_C − HYSTERESIS_C`. Wider = more stable, less aggressive. |
| `INTERVAL_S`   | `15`    | Seconds between polls. |
| `MIN_UTIL`     | `25`    | Only raise a GPU whose utilization is above this %. |
| `STEP_W`       | `5`     | Raise step, in watts. |
| `MAX_STEP_W`   | `15`    | Largest single reduce step, in watts. |
| `GPUS`         | `all`   | Comma-separated UUIDs and/or indices to manage, or `all`. |
| `DRY_RUN`      | `0`     | `1` = log decisions but never change power limits. |
| `LGC_MIN_MHZ`  | `210`   | *(clock fallback)* idle floor for the clock lock. |
| `MIN_CAP_MHZ`  | `600`   | *(clock fallback)* never cap the max clock below this (keep card usable). |
| `CLOCK_STEP_MHZ` | `90`  | *(clock fallback)* raise step, in MHz. |
| `MAX_CLOCK_STEP_MHZ` | `300` | *(clock fallback)* largest single reduce step, in MHz. |

Example — hold everything at ≤70 °C, poll every 10 s:

```ini
Environment=TARGET_C=70
Environment=INTERVAL_S=10
```

Example — manage only two specific cards:

```ini
Environment=GPUS=0,GPU-xxxxxxxx-....
```

## Notes & safety

- The daemon only ever sets power limits within each card's
  **hardware-reported min/max** — it can't push a card beyond its rated range.
- It's a control loop, not a hard interlock: with a sudden load spike a card can
  briefly exceed `TARGET_C` for up to one poll interval before being reined in.
  Keep `TARGET_C` a comfortable margin below your card's throttle temperature
  (typically ~83–90 °C), and/or shorten `INTERVAL_S`.
- Power capping is a *cooling* lever, not a substitute for airflow. If a card is
  hot, better fans/ducting let the autotuner allow higher caps within the same
  temperature budget.
- It does not touch fan control or clocks — only the power limit.

## License

MIT — see [LICENSE](LICENSE).
