#!/usr/bin/env bash
# nvidia-thermal-autotuner — keep every NVIDIA GPU under a target temperature by
# continuously autotuning its power limit.
#
# Each GPU is driven toward its hardware-maximum power and bounded ONLY by
# temperature: raise the power limit when the card is cool and busy, lower it
# when it gets hot. There are no fixed per-card caps — the controller discovers
# each card's maximum sustainable power at your target temperature on the fly.
#
# This is handy for:
#   - GPUs in restricted airflow (sandwiched in multi-GPU rigs, blower-starved
#     chassis, servers whose fan curves don't recognize the card, etc.)
#   - mixed-GPU machines (each card finds its own limit)
#   - keeping a rig quiet/cool 24/7 without leaving performance on the table
#
# It pins by GPU UUID, so it is robust to nvidia-smi index reshuffling when GPUs
# are added or removed.
#
# Configuration (environment variables, all optional):
#   TARGET_C       Target ceiling temperature in C; reduce at/above it.  (default 80)
#   HYSTERESIS_C   Only raise when temp <= TARGET_C - HYSTERESIS_C.       (default 5)
#   INTERVAL_S     Seconds between polls.                                (default 15)
#   MIN_UTIL       Only raise a GPU busier than this % (so an idle        (default 25)
#                  card's cool temperature doesn't trigger a raise).
#   STEP_W         Raise step, in watts.                                 (default 5)
#   MAX_STEP_W     Largest single reduce step, in watts.                 (default 15)
#   GPUS           Comma-separated GPU UUIDs and/or indices to manage,    (default all)
#                  or "all".
#   DRY_RUN        If 1, log decisions but never change power limits.     (default 0)
#
# Mobile/laptop GPUs often expose no settable power limit (power.limit reads N/A
# and `-pl` is rejected). For those, the daemon falls back to autotuning the max
# SM clock (`nvidia-smi -lgc`) with the SAME temperature loop:
#   LGC_MIN_MHZ         Idle floor for the clock lock.                  (default 210)
#   MIN_CAP_MHZ         Never cap the max clock below this (stay usable).(default 600)
#   CLOCK_STEP_MHZ      Raise step, in MHz.                             (default 90)
#   MAX_CLOCK_STEP_MHZ  Largest single reduce step, in MHz.             (default 300)
#
# Requirements: nvidia-smi, and privilege to set power limits / clocks (run as
# root or with CAP_SYS_ADMIN). The daemon enables persistence mode on start.
#
# SPDX-License-Identifier: MIT
set -uo pipefail

TARGET_C="${TARGET_C:-80}"
HYSTERESIS_C="${HYSTERESIS_C:-5}"
INTERVAL_S="${INTERVAL_S:-15}"
MIN_UTIL="${MIN_UTIL:-25}"
STEP_W="${STEP_W:-5}"
MAX_STEP_W="${MAX_STEP_W:-15}"
GPUS="${GPUS:-all}"
DRY_RUN="${DRY_RUN:-0}"

# Clock-control fallback: some GPUs (notably mobile/laptop cards) report no
# settable power limit (`power.limit` reads N/A and `-pl` is rejected). For those,
# hold TARGET_C by autotuning the card's max SM clock with `-lgc` instead, using
# the same closed loop. Desktop cards keep using the power-limit path above.
LGC_MIN_MHZ="${LGC_MIN_MHZ:-210}"                  # idle floor for the clock lock
MIN_CAP_MHZ="${MIN_CAP_MHZ:-600}"                  # never cap the max clock below this (keep card usable)
CLOCK_STEP_MHZ="${CLOCK_STEP_MHZ:-90}"             # raise step (MHz)
MAX_CLOCK_STEP_MHZ="${MAX_CLOCK_STEP_MHZ:-300}"    # largest single reduce step (MHz)

RAISE_BELOW=$(( TARGET_C - HYSTERESIS_C ))

log(){ printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

command -v nvidia-smi >/dev/null 2>&1 || { log "FATAL: nvidia-smi not found in PATH"; exit 1; }

# Optional GPU allow-list: resolve any indices to UUIDs so matching is stable.
declare -A WANT=()
if [[ "$GPUS" != "all" ]]; then
  mapfile -t allmap < <(nvidia-smi --query-gpu=index,uuid --format=csv,noheader,nounits 2>/dev/null)
  IFS=',' read -ra sel <<< "$GPUS"
  for s in "${sel[@]}"; do
    s="${s// /}"
    for row in "${allmap[@]}"; do
      idx="${row%%,*}"; idx="${idx// /}"; uu="${row#*,}"; uu="${uu// /}"
      [[ "$s" == "$uu" || "$s" == "$idx" ]] && WANT["$uu"]=1
    done
  done
fi
want(){ [[ "$GPUS" == "all" ]] && return 0; [[ -n "${WANT[$1]:-}" ]]; }

if [[ "$DRY_RUN" != "1" ]]; then
  nvidia-smi -pm 1 >/dev/null 2>&1 || log "warn: could not enable persistence mode (continuing)"
fi
log "up: TARGET=${TARGET_C}C raise<=${RAISE_BELOW}C min_util=${MIN_UTIL}% interval=${INTERVAL_S}s step=${STEP_W}W gpus=${GPUS} dry_run=${DRY_RUN}"

set_pl(){ # $1=uuid $2=watts
  [[ "$DRY_RUN" == "1" ]] && return 0
  nvidia-smi -i "$1" -pl "$2" >/dev/null 2>&1
}

set_lgc(){ # $1=uuid $2=max-clock-MHz  (locks [LGC_MIN_MHZ, $2]; idle still clocks down)
  [[ "$DRY_RUN" == "1" ]] && return 0
  nvidia-smi -i "$1" -lgc "${LGC_MIN_MHZ},$2" >/dev/null 2>&1
}

declare -A CLKCAP=() CLKMODE=()   # per-UUID current clock cap + "in clock mode" flag

while true; do
  out="$(nvidia-smi --query-gpu=uuid,power.limit,power.min_limit,power.max_limit,temperature.gpu,utilization.gpu,clocks.max.sm \
                    --format=csv,noheader,nounits 2>/dev/null)" \
    || { log "nvidia-smi query failed; retrying in ${INTERVAL_S}s"; sleep "$INTERVAL_S"; continue; }
  while IFS=',' read -r uuid lim minp maxp temp util maxclk; do
    uuid="${uuid// /}"; lim="${lim// /}"; lim="${lim%.*}"
    minp="${minp// /}"; minp="${minp%.*}"; maxp="${maxp// /}"; maxp="${maxp%.*}"
    temp="${temp// /}"; temp="${temp%.*}"; util="${util// /}"
    maxclk="${maxclk// /}"; maxclk="${maxclk%.*}"
    [[ -z "$uuid" || -z "$temp" ]] && continue
    want "$uuid" || continue
    short="${uuid:4:8}"
    if [[ "$minp" =~ ^[0-9]+$ && "$maxp" =~ ^[0-9]+$ && "$lim" =~ ^[0-9]+$ ]]; then
      # ---- POWER-LIMIT control (desktop / server cards) ----
      if (( temp >= TARGET_C && lim > minp )); then
        over=$(( temp - TARGET_C )); step=$(( (over + 1) * 3 ))
        (( step > MAX_STEP_W )) && step=$MAX_STEP_W; (( step < 3 )) && step=3
        new=$(( lim - step )); (( new < minp )) && new=$minp
        (( new != lim )) && { set_pl "$uuid" "$new" && log "REDUCE  $short ${temp}C util${util}% ${lim}->${new}W"; }
      elif (( temp <= RAISE_BELOW && util >= MIN_UTIL && lim < maxp )); then
        new=$(( lim + STEP_W )); (( new > maxp )) && new=$maxp
        (( new != lim )) && { set_pl "$uuid" "$new" && log "RAISE   $short ${temp}C util${util}% ${lim}->${new}W (max ${maxp})"; }
      fi
    elif [[ "$maxclk" =~ ^[0-9]+$ ]] && (( maxclk > 0 )); then
      # ---- CLOCK control (mobile cards whose power limit isn't settable) ----
      if [[ -z "${CLKMODE[$uuid]:-}" ]]; then
        CLKMODE[$uuid]=1; CLKCAP[$uuid]=$maxclk
        set_lgc "$uuid" "$maxclk"   # establish a known state, clearing any stale -lgc lock
        log "mode    $short power-limit not settable -> CLOCK control (max ${maxclk}MHz)"
      fi
      cur=${CLKCAP[$uuid]}
      if (( temp >= TARGET_C && cur > MIN_CAP_MHZ )); then
        over=$(( temp - TARGET_C )); step=$(( (over + 1) * CLOCK_STEP_MHZ ))
        (( step > MAX_CLOCK_STEP_MHZ )) && step=$MAX_CLOCK_STEP_MHZ; (( step < CLOCK_STEP_MHZ )) && step=$CLOCK_STEP_MHZ
        new=$(( cur - step )); (( new < MIN_CAP_MHZ )) && new=$MIN_CAP_MHZ
        (( new != cur )) && { set_lgc "$uuid" "$new" && CLKCAP[$uuid]=$new && log "REDUCE-CLK $short ${temp}C util${util}% ${cur}->${new}MHz"; }
      elif (( temp <= RAISE_BELOW && util >= MIN_UTIL && cur < maxclk )); then
        new=$(( cur + CLOCK_STEP_MHZ )); (( new > maxclk )) && new=$maxclk
        (( new != cur )) && { set_lgc "$uuid" "$new" && CLKCAP[$uuid]=$new && log "RAISE-CLK  $short ${temp}C util${util}% ${cur}->${new}MHz (max ${maxclk})"; }
      fi
    fi
  done <<< "$out"
  sleep "$INTERVAL_S"
done
