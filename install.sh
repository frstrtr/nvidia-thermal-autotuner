#!/usr/bin/env bash
# Install nvidia-thermal-autotuner as a systemd service.
# Usage:  sudo ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

install -m 0755 nvidia-thermal-autotuner.sh /usr/local/bin/nvidia-thermal-autotuner.sh
install -m 0644 nvidia-thermal-autotuner.service /etc/systemd/system/nvidia-thermal-autotuner.service

systemctl daemon-reload
systemctl enable --now nvidia-thermal-autotuner.service

echo "Installed and started nvidia-thermal-autotuner."
echo "Configure it by editing /etc/systemd/system/nvidia-thermal-autotuner.service"
echo "  (e.g. add 'Environment=TARGET_C=75'), then: systemctl daemon-reload && systemctl restart nvidia-thermal-autotuner"
echo "Watch it:  journalctl -u nvidia-thermal-autotuner -f"
