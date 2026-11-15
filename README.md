# Orange Pi Zero 3W: PCIe fix for Raspberry Pi 5 PCIe HATs

The Orange Pi Zero 3W (Allwinner A733) has a 16-pin PCIe FPC connector with the same
pinout as the Raspberry Pi 5. Out of the box, though, Pi 5 PCIe HATs don't work. The
vendor device tree leaves out two PCIe sideband GPIOs:

| FPC pin | Signal | SoC pin |
|---|---|---|
| 13 | PCIE_PWR_EN | **PD23** |
| 16 | PCIE_RST_B (PERST#) | **PD22** |

PWR_EN is never driven, so the HAT never switches on power to its slot, and the link
never trains. At every boot the kernel logs:

```
sunxi:pcie-6000000.pcie:[WARN]: Failed to get "power-gpios"
sunxi:pcie-6000000.pcie:[WARN]: Failed to get "reset-gpios"
sunxi:pcie-rc-6000000.pcie:[ERR]: Speed change timeout
```

This repo has a device tree overlay that adds both pins, so the PCIe driver powers and
resets the slot properly. No jumper wires or hardware changes are needed.

**Tested with:** an Orange Pi Zero 3W on the stock Orange Pi image (kernel
`6.6.98-sun60iw2`), a Pineboards uPCIty Lite HAT, and a Fresco Logic FL1100 USB 3.0 card.
The card enumerates at 5 GT/s x1 (its maximum), and a USB SSD on it reads at about 335 MB/s.

## Repository contents

| File | What it is | Where it goes on the Pi |
|---|---|---|
| `overlay/pcie-pwren.dts` | Overlay source | Optional: `/boot/overlay-user/pcie-pwren.dts`, kept for reference |
| `overlay/pcie-pwren.dtbo` | Compiled overlay | **`/boot/overlay-user/pcie-pwren.dtbo`** |
| `tools/ltssm.py` | Prints the PCIe link-training state, for diagnosis | Anywhere, e.g. `~/bin/`. Run with `sudo` |
| `tools/probe_pwren.sh` | The GPIO probe used to find PD23 | Anywhere. Only needed to repeat the investigation |
| `docs/full-story.md` | The full debugging write-up | Not needed on the Pi |

## Installation

### 1. Hardware

- Use a **short FPC cable, 50mm or less**, as the Raspberry Pi PCIe spec requires. Use the
  one supplied with your HAT if possible. Longer cables can work once and then fail
  with exactly the symptoms above.
- If your HAT needs its own power (e.g. the 12V input on the uPCIty Lite), connect it.
- **Remove any jumper you added to force PWR_EN high.** The overlay replaces it.

### 2. Install the overlay

Using the prebuilt `.dtbo`:

```sh
sudo mkdir -p /boot/overlay-user
sudo cp overlay/pcie-pwren.dtbo /boot/overlay-user/
sudo cp overlay/pcie-pwren.dts  /boot/overlay-user/   # optional, for reference
```

Or build it from source (needs `device-tree-compiler`):

```sh
dtc -@ -I dts -O dtb -o pcie-pwren.dtbo overlay/pcie-pwren.dts
sudo cp pcie-pwren.dtbo /boot/overlay-user/
```

### 3. Enable it in `/boot/orangepiEnv.txt`

Back up the file first:

```sh
sudo cp /boot/orangepiEnv.txt /boot/orangepiEnv.txt.bak
```

- **No `user_overlays=` line yet:** add one:
  ```sh
  echo 'user_overlays=pcie-pwren' | sudo tee -a /boot/orangepiEnv.txt
  ```
- **`user_overlays=` line already exists:** add `pcie-pwren` to the end of that line,
  separated by a space, e.g. `user_overlays=something pcie-pwren`. Don't add a second line.

The stock Orange Pi `boot.scr` loads every overlay named there from `/boot/overlay-user/`.

Optional: check the overlay applies cleanly to your board's DTB before rebooting:

```sh
fdtoverlay -i /boot/dtb/allwinner/sun60i-a733-orangepi-zero3w.dtb \
           -o /tmp/test.dtb /boot/overlay-user/pcie-pwren.dtbo
fdtget -t x /tmp/test.dtb /soc@3000000/pcie@6000000 power-gpios   # expect: 36 3 17 0
fdtget -t x /tmp/test.dtb /soc@3000000/pcie@6000000 reset-gpios   # expect: 36 3 16 0
```

The first number is the pin controller's phandle and could differ on other image
versions. It should match the existing `wake-gpios` property.

### 4. Reboot and verify

```sh
sudo reboot
```

Then:

```sh
sudo dmesg | grep -iE 'Failed to get|sunxi:pcie-rc'
# expect "pcie link up success" and no "Failed to get" lines

sudo cat /sys/kernel/debug/gpio | grep -E 'gpio-11[789]'
#  gpio-117 (...|wake  ) out hi    PD21
#  gpio-118 (...|reset ) out hi    PD22
#  gpio-119 (...|power ) out hi    PD23

lspci        # your device should appear as 01:00.0
```

## Uninstall or roll back

Remove `pcie-pwren` from the `user_overlays=` line in `/boot/orangepiEnv.txt` (or restore
your `.bak`) and reboot. If the Pi won't boot, you can edit that file from another computer:
it's on the SD card's root filesystem at `/boot/orangepiEnv.txt`.

## Troubleshooting

- **`Speed change timeout`, and `lspci` shows only `00:00.0`:** run `sudo tools/ltssm.py`.
  - `LTSSM=0x03`: the far end was detected but never transmits. Check the slot has
    power, that PWR_EN is high at the HAT, and the **FPC length** (≤50mm).
  - `LTSSM=0x00`: nothing was detected. Check the cable is seated and the right way round.
- **Breakout boards and jumper wires in the PCIe path won't work,** even if every pin
  measures correctly. The high-speed lanes can't survive it.
- **Measuring at the slot with the HAT not enabled is misleading.** PERST# and one REFCLK
  leg can read low or odd, which makes good hardware look broken.
- **To reset a card without rebooting:** detach it with
  `echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/remove`, pulse PD22 low, then
  `echo 1 | sudo tee /sys/bus/pci/rescan`.

See [`docs/full-story.md`](docs/full-story.md) for the full investigation: measurements,
the GPIO hunt, and the PERST# test.

## Upstream

The proper fix is two lines in the Zero 3W's device tree, on the `pcie@6000000` node.
The Orange Pi 4 Pro (same SoC) already has the reset line:

```dts
power-gpios = <&pio 3 23 0>; /* PD23 */
reset-gpios = <&pio 3 22 0>; /* PD22 */
```

## License

MIT. See [LICENSE](LICENSE).
