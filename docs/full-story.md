# Getting PCIe working on the Orange Pi Zero 3W

**Board:** Orange Pi Zero 3W (Allwinner A733), stock Orange Pi image, kernel `6.6.98-sun60iw2`
**Adapter:** Pineboards uPCIty Lite (a Raspberry Pi 5 PCIe HAT, with its own 12V feed)
**Test device:** Fresco Logic FL1100 USB 3.0 host controller card
**Result:** the card enumerates at boot as `01:00.0`, link 5 GT/s x1, with no hardware modifications.

---

## TL;DR

1. The Orange Pi's PCIe FPC uses the same 16-pin layout as the Raspberry Pi 5, but the
   Zero 3W never drives **PCIE_PWR_EN (pin 13)**. With pin 13 low, a Pi 5-style HAT
   never switches on power to its slot.
2. Pin 13 is wired to SoC GPIO **PD23**, but Orange Pi's device tree doesn't declare it.
   The driver logs `Failed to get "power-gpios"` at every boot.
3. **PCIE_RST_B / PERST# (pin 16)** is wired to **PD22**, also undeclared. The board
   holds it high, so cards work without it, but nothing ever gives them a reset pulse.
4. A small device tree overlay declares both pins on the PCIe node:
   `power-gpios = <&pio 3 23 0>` and `reset-gpios = <&pio 3 22 0>`. The driver then
   raises PWR_EN at boot, handles PERST#, and the device appears.
5. Use a **short FPC** (≤50mm, per the Raspberry Pi spec). Longer cables can work
   sometimes and then fail.

---

## The route we took

### 1. Measure every pin with a PCIe device connected

With a device connected, I measured every pin of the FPC with a multimeter and compared
them against a Raspberry Pi 5.

- Pins 4 and 5 (PCIE_CLK_P / PCIE_CLK_N) carry the 100 MHz reference clock. On a scope
  they show a clock. On a multimeter each leg reads an average of about 400mV.
- **Pin 13 (PCIE_PWR_EN) was low.** On a Pi 5 it's high.

The kernel agreed something was wrong. The link never trained, and nothing appeared
behind the root bridge:

```
sunxi:pcie-6000000.pcie:[WARN]: Failed to get "power-gpios"
sunxi:pcie-6000000.pcie:[WARN]: Failed to get "reset-gpios"
sunxi:pcie-rc-6000000.pcie:[ERR]: Speed change timeout
```

Reading the controller's debug register showed the link-training state machine (LTSSM)
stuck at `0x03` (Polling.Compliance). The root port could see the far end, but the
device never sent anything back, because its slot had no power.

### 2. Work around it with a jumper on the uPCIty Lite

The uPCIty Lite has test pads, including one for pin 13. I ran a jumper from that pad
through a **10k resistor** to the Orange Pi's 3.3V rail. With a **short FPC**, the USB3
controller in the slot showed up fine.

Note: the HAT's PWR_EN input loads the line like about 27k to ground. With 10k in
series the pad sits at about 2.4V, which was enough. A **1k** resistor gives about 3.1V,
which leaves more margin.

### 3. Try a breakout board, and learn about the 50mm rule

I tried two FPC → pin-header breakout boards wired pin-for-pin, feeding pin 13 straight
from the Pi's 3.3V rail. Every pin measured as expected, except the PCIe TX/RX pins
(7/8/10/11), which all read low, and **no device showed up**.

The reason: the wires between the two breakout boards break the Raspberry Pi 5 rule
that the FPC must be **≤50mm and controlled impedance**. The sideband signals (power,
reset, PWR_EN) survive that kind of wiring and measure fine, but the high-speed TX/RX
lanes don't.

Even a slightly-too-long FPC is marginal. My original over-length cable worked once,
then stopped. The short cable supplied with the uPCIty Lite has been reliable.

### 4. Go back to the known-good setup

I removed the breakout boards and connected the uPCIty Lite directly with the short FPC
plus the pin 13 jumper, and confirmed the device came back.

### 5. Find which GPIO drives pin 13

The sibling **Orange Pi 4 Pro** (same A733 SoC, same PCIe driver) has
`reset-gpios` = PD22 and `wake-gpios` = PD21 in its device tree. The Zero 3W's tree
only has `wake-gpios` = PD21. So PWR_EN was probably an undeclared pin in the PD bank.

PD0–PD4 go to the 40-pin header, which left **PD5–PD20, PD22 and PD23** as candidates.

Test rig, to keep the HAT and card out of harm's way:

- Orange Pi → FPC → **one** breakout board (no HAT, no PCIe card).
- Pin 13 → **100k** to GND, standing in for the HAT's pull-down so an undriven pin reads 0V.
- Pin 13 → **LED + 330Ω** to GND as a visual indicator.

A script drove each candidate pin high for 5 seconds, then released it back to a
high-impedance input:

```sh
#!/bin/sh
# Drive each candidate PD pin high for 5s, then release it (input, high-Z).
# PDn = gpio (96 + n) on gpiochip0.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
for p in 22 23 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5; do
  n=$((96 + p))
  echo $n > /sys/class/gpio/export 2>/dev/null || { echo "PD$p: export failed, skipping"; continue; }
  echo out > /sys/class/gpio/gpio$n/direction
  echo 1 > /sys/class/gpio/gpio$n/value
  printf 'PD%-2s (gpio %s) HIGH ... ' $p $n
  sleep 5
  echo in > /sys/class/gpio/gpio$n/direction
  echo $n > /sys/class/gpio/unexport
  echo released
  sleep 2
done
```

**PD23 (gpio 119)** lit the LED, and it went out when the pin was released. Driving
PD23 high on its own confirmed 3.3V on pin 13.

### 6. Add a device tree overlay

`/boot/overlay-user/pcie-pwren.dts`:

```dts
/dts-v1/;
/plugin/;

/*
 * Orange Pi Zero 3W: PCIe sideband GPIOs missing from the vendor DT.
 *   PCIE_PWR_EN (FPC pin 13) = PD23
 *   PCIE_RST_B  (FPC pin 16) = PD22 (PERST#)
 * Same layout as the Orange Pi 4 Pro (which also has wake on PD21).
 */
/ {
	fragment@0 {
		target-path = "/soc@3000000/pcie@6000000";
		__overlay__ {
			power-gpios = <&pio 3 23 0>; /* PD23, active high */
			reset-gpios = <&pio 3 22 0>; /* PD22, as in the OPi 4 Pro DT */
		};
	};
};
```

(At first the overlay had only `power-gpios`. `reset-gpios` was added after step 8.)

Compile and install:

```sh
dtc -@ -I dts -O dtb -o pcie-pwren.dtbo pcie-pwren.dts
sudo mkdir -p /boot/overlay-user
sudo cp pcie-pwren.dtbo /boot/overlay-user/
echo 'user_overlays=pcie-pwren' | sudo tee -a /boot/orangepiEnv.txt
```

If `orangepiEnv.txt` already has a `user_overlays=` line, append `pcie-pwren` to that
line instead of adding a second one. The stock `boot.scr` loads anything listed there
from `/boot/overlay-user/`.

Optional: check it applies cleanly before rebooting:

```sh
fdtoverlay -i /boot/dtb/allwinner/sun60i-a733-orangepi-zero3w.dtb \
           -o /tmp/test.dtb pcie-pwren.dtbo
fdtget -t x /tmp/test.dtb /soc@3000000/pcie@6000000 power-gpios   # expect: 36 3 17 0
fdtget -t x /tmp/test.dtb /soc@3000000/pcie@6000000 reset-gpios   # expect: 36 3 16 0
```

(`0x17` = 23, `0x16` = 22. `0x36` is the pin controller's phandle, the same one
`wake-gpios` uses.)

### 7. Final test: no jumper

I reconnected the uPCIty Lite with the short FPC and **without the jumper**. The USB3
controller showed up at boot:

```
$ sudo dmesg | grep -iE 'power-gpios|sunxi:pcie-rc'
sunxi:pcie-rc-6000000.pcie:[INFO]: pcie link up success

$ sudo cat /sys/kernel/debug/gpio | grep gpio-119
 gpio-119 (                    |power               ) out hi

$ lspci -nn
00:00.0 PCI bridge [0604]: Device [1f6d:abcd] (rev 01)
01:00.0 USB controller [0c03]: Fresco Logic FL1100 USB 3.0 Host Controller [1b73:1100] (rev 10)
```

The `Failed to get "power-gpios"` warning is gone. The link runs at 5 GT/s x1, which is
the FL1100's maximum because it's a Gen2 part.

### 8. Identify PERST# (PD22)

The driver still logged `Failed to get "reset-gpios"`. The Orange Pi 4 Pro uses PD22 for
reset, so we tested PD22 live, with the card running, instead of rewiring the breakout:

1. Detach the card in software so the kernel doesn't touch it while it's in reset:
   `echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove`
2. Drive PD22 low (`gpio 118`) and watch the link state in the root port's own debug
   register (DBI base `0x06000000`, LTSSM = `reg 0x728 & 0x3f`):

| Step | LTSSM | Card |
|---|---|---|
| Before | `0x11` (L0, link up) | `01:00.0` present |
| Card removed in sysfs | `0x11` | gone from `lspci` |
| **PD22 driven low** | **`0x00` (Detect.Quiet, link down)** | held in reset |
| PD22 released (input) | `0x11` within a second | retrained by itself |
| `echo 1 \| sudo tee /sys/bus/pci/rescan` | `0x11` | back, 5 GT/s x1, `xhci_hcd` bound |

So **PD22 is PERST#**. The controller retrained on its own, and a PCI rescan brought the
card back without a reboot.

I added `reset-gpios = <&pio 3 22 0>;` to the overlay, written the same way as in the
Orange Pi 4 Pro's DT. The driver then holds the card in reset while power comes up and
releases it before link training.

After rebooting with the full overlay, neither `Failed to get` warning appears, the link
comes up first time, and the driver claims all three sideband pins:

```
$ sudo cat /sys/kernel/debug/gpio | grep -E 'gpio-11[789]'
 gpio-117 (                    |wake                ) out hi
 gpio-118 (                    |reset               ) out hi
 gpio-119 (                    |power               ) out hi
```

---

## Reference

### FPC pins that mattered

Numbering as printed on the Orange Pi and the uPCIty Lite.

| FPC pin | Signal | x1 slot pin | Notes |
|---|---|---|---|
| 4 | PCIE_CLK_P | A13 | 100 MHz clock, about 400mV on a meter |
| 5 | PCIE_CLK_N | A14 | 100 MHz clock, about 400mV on a meter |
| 13 | PCIE_PWR_EN | (HAT enable) | **PD23**, needs the overlay |
| 16 | PCIE_RST_B | A11 | PERST#, **PD22**, held high on the board, overlay hands it to the driver |

### Zero 3W PCIe GPIOs

| Function | Pin | In vendor DT? |
|---|---|---|
| wake | PD21 (gpio 117) | yes |
| power (PWR_EN) | **PD23 (gpio 119)** | **no**, added by the overlay |
| reset (PERST#) | **PD22 (gpio 118)** | **no**, added by the overlay |

### Lessons learned

- **The FPC length limit is real.** Keep it ≤50mm. Over-length cables can work once and
  then fail. Breakout boards in the PCIe path never work, even when every pin looks right
  on a meter.
- **Slot readings are misleading while the HAT is switched off.** With PWR_EN low, slot
  pins such as PERST# and one REFCLK leg can read low or odd, which makes a good card or
  a good Pi look faulty.
- **The failure signature:** `Speed change timeout` in `dmesg`, nothing behind the root
  bridge in `lspci`, and LTSSM stuck at `0x03` (Polling.Compliance).
- **Prefer a reboot** over unbinding and rebinding the `sunxi-pcie` driver to retrain the
  link. Rebinding, combined with raw register reads, hung the Pi once.
- **To reset a card without rebooting:** remove it in sysfs, pulse PERST# (PD22), then
  `echo 1 > /sys/bus/pci/rescan`. Detaching first matters, because touching a card while
  it's in reset can hang Arm SoCs.

### Possible follow-ups

- **Upstream:** Orange Pi's Zero 3W device tree should get the two-line fix
  `power-gpios = <&pio 3 23 0>;` and `reset-gpios = <&pio 3 22 0>;` on the PCIe node.
- **Rollback:** the power-only overlay is saved alongside as `pcie-pwren.dtbo.bak` /
  `.dts.bak` in `/boot/overlay-user/`.
- **Reflashing:** keep a copy of `pcie-pwren.dtbo` / `.dts` off the Pi. After a reflash,
  copy it back and add the `user_overlays` line again.
