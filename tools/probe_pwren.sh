#!/bin/sh
# Find which PD-bank GPIO drives a given PCIe FPC pin (used to find PWR_EN = PD23).
# Drives each candidate PD pin high for 5s, then releases it (input, high-Z).
# Watch the FPC pin under test (e.g. LED + 330R to GND, 100k pull-down) on a breakout.
# PDn = gpio (96 + n) on gpiochip0. PD0-PD4 are on the 40-pin header; PD21 is PCIe wake.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
for p in 22 23 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5; do
  n=$((96 + p))
  echo $n > /sys/class/gpio/export 2>/dev/null || { echo "PD$p: export failed (in use?), skipping"; continue; }
  echo out > /sys/class/gpio/gpio$n/direction
  echo 1 > /sys/class/gpio/gpio$n/value
  printf 'PD%-2s (gpio %s) HIGH ... ' $p $n
  sleep 5
  echo in > /sys/class/gpio/gpio$n/direction
  echo $n > /sys/class/gpio/unexport
  echo released
  sleep 2
done
echo done
