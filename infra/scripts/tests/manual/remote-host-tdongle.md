# Manual procedure — remote-host integration with T-Dongle-S3

This walks the s010 remote-host registration end-to-end against real
hardware: an Orange Pi (or any other Linux device-host) with a
LilyGo T-Dongle-S3 attached. The substrate registers the Pi as a
remote host, the agent installs `esptool` and PlatformIO on the Pi,
builds the LilyGo LED example for the T-Dongle-S3, flashes it via
the Pi's USB-CDC link, reads back the boot banner, and observes the
RGB LED cycle. **The grep on the boot banner is the assertion.**

The hardware-less loopback equivalent (alpine+sshd sidecars) is
Phase 17 of `infra/scripts/tests/test-substrate-end-to-end.sh`. This
file is the real-hardware procedure.

## Preconditions

1. **Linux device-host** (Orange Pi, Raspberry Pi, repurposed
   Chromebook, etc.) on the same LAN as the substrate host:
   - Reachable IP: `192.168.16.179` (substitute your own).
   - User with passwordless sudo: `jon` (substitute your own).
   - **Passwordless SSH from your operator shell** to that user:
     ```
     ssh-copy-id jon@192.168.16.179
     ssh jon@192.168.16.179 'sudo -n true'   # confirm
     ```
   - `python3` installed (most Linux distros, including Armbian and
     Raspberry Pi OS, ship with it). The bootstrap step 5 verifies
     this.

2. **T-Dongle-S3** plugged into a USB-A port on the device-host.
   Verify it enumerates:
   ```
   ssh jon@192.168.16.179 'lsusb | grep -i ESP; ls /dev/ttyACM*'
   ```
   The device should show as `/dev/ttyACM0` (USB-CDC). If you see
   `/dev/ttyUSB0` instead, the bootloader has booted into UART mode;
   reconnect with the boot button held briefly.

3. **Substrate up** with the platformio-esp32 platform selected:
   ```
   cd /path/to/turtle-core
   ./setup-linux.sh --platform=platformio-esp32
   ```
   You can skip `--device=` since the embedded board lives on the
   Pi, not on the host. The s009 device-required warning will
   appear once; ignore it for HIL via remote-host.

## Step 1 — register the remote host

```
./setup-linux.sh --add-remote-host=tdongle-pi=jon@192.168.16.179
```

Expected output (paraphrased):

```
[add] --add-remote-host=tdongle-pi=jon@192.168.16.179
[bootstrap-remote-host] tdongle-pi: jon@192.168.16.179:22
[bootstrap-remote-host] tdongle-pi: generating ed25519 keypair → infra/keys/remote-hosts/tdongle-pi/id_ed25519
[bootstrap-remote-host] tdongle-pi: capturing host key via ssh-keyscan -p 22 192.168.16.179
[bootstrap-remote-host] tdongle-pi: installing substrate pubkey on jon@192.168.16.179 (using operator credentials)
[bootstrap-remote-host] tdongle-pi: verifying substrate-key-only access (sudo -n + python3)
[bootstrap-remote-host] tdongle-pi: registered.
[render-ssh-config] wrote .substrate-state/ssh-config + 3 role copies
[add] --add-remote-host: tdongle-pi registered. Running containers see the new stanza
[add]   via the live bind-mount of .substrate-state/ssh-config and infra/keys/<role>/config.
[add]   No image rebuild, no compose restart.
```

If step 4 (pubkey install) fails, the diagnostic names the host
and the cause; the most common case is "operator's passwordless
SSH isn't set up" — re-run `ssh-copy-id` and try again.

## Step 2 — smoke check from coder-daemon

Before starting any real work, verify the role container can reach
the registered host:

```
docker compose run --rm coder-daemon bash -c \
    'ssh tdongle-pi "lsusb | grep -i ESP"'
```

Expected: a single `Bus ... Device ... ID ...` line for the ESP32-S3
(VID `303a:1001` for native USB-CDC).

## Step 3 — install esptool on the remote

The substrate doesn't pre-install agent tooling on remote hosts (per
design call 2). The agent installs on demand. From the
coder-daemon shell (commissioned via commission-pair.sh, or a
one-shot `docker compose run --rm coder-daemon bash`):

```
ssh tdongle-pi 'pip install --user --break-system-packages esptool'
ssh tdongle-pi '~/.local/bin/esptool --version'
```

(`--break-system-packages` is needed on PEP 668-compliant distros;
you can also use a venv: `python3 -m venv ~/esp-venv &&
~/esp-venv/bin/pip install esptool`.)

For the build step, also install PlatformIO:

```
ssh tdongle-pi 'pip install --user --break-system-packages platformio'
ssh tdongle-pi '~/.local/bin/pio --version'
```

## Step 4 — build the LilyGo LED example

The reference example lives in
`https://github.com/Xinyuan-LilyGO/T-Dongle-S3/tree/main/examples/led`.
Wrap it as a PlatformIO project on the Pi:

```
ssh tdongle-pi '
    set -e
    workdir=$(mktemp -d)
    cd "$workdir"
    git clone --depth=1 https://github.com/Xinyuan-LilyGO/T-Dongle-S3
    cp -r T-Dongle-S3/examples/led .
    cd led
    cat > platformio.ini <<INI
[env:t-dongle-s3]
platform = espressif32
framework = arduino
board = lilygo-t-dongle-s3
lib_deps = fastled/FastLED@^3.6.0
build_flags = -DARDUINO_USB_CDC_ON_BOOT=1
INI
    mkdir -p src
    # The example has the .ino at the top of examples/led; the
    # exact filename varies. Move it into src/ as main.cpp.
    mv *.ino src/main.cpp 2>/dev/null || mv */*.ino src/main.cpp
    PATH="$HOME/.local/bin:$PATH" pio run
'
```

If `lilygo-t-dongle-s3` isn't a recognised board name on your PIO
install, fall back to `board = esp32-s3-devkitc-1` and add the
appropriate `board_build.flash_size = 4MB` /
`board_build.flash_mode = qio` flags. Refer to LilyGo's README for
the canonical config.

The build artifact lands at
`.pio/build/t-dongle-s3/firmware.bin` on the Pi.

## Step 5 — flash

The T-Dongle-S3 enumerates as `/dev/ttyACM0`. esptool over USB-CDC
is straightforward:

```
ssh tdongle-pi '
    cd $(ls -dt /tmp/tmp.* | head -1)/led
    ~/.local/bin/esptool --chip esp32s3 --port /dev/ttyACM0 \
        --baud 921600 write_flash -z 0x0 .pio/build/t-dongle-s3/firmware.bin
'
```

Expected: esptool's familiar progress bar, ending with
`Hash of data verified.` and a leave-the-flash-mode message.

## Step 6 — read the boot banner (the assertion)

```
ssh tdongle-pi '
    stty -F /dev/ttyACM0 115200 raw -echo
    timeout 10 cat /dev/ttyACM0
' | tee /tmp/serial.log
grep -F "Start T-Dongle-S3 LED example" /tmp/serial.log
```

Expected: the log captures the ESP-IDF boot banner followed by the
example's `setup()` print:
```
Start T-Dongle-S3 LED example
```

The grep is the assertion. If it returns 0 lines, capture the full
serial log into the section report and triage (reset the board with
the hardware reset button, re-flash, re-read).

## Step 7 — visual smoke check (human in the loop)

The example cycles the on-board APA102 LED:

- During `setup()`: red, green, blue, off, ~250ms each.
- During `loop()`: random RGB, ~100ms.

This is a pure-visual confirmation; not automated. Operator
observes for a few seconds and notes "LED cycling as expected" in
the section report.

## Captures for the section report

Append to `briefs/s010-remote-host-integration/section.report.md`:

- The full `--add-remote-host` transcript (step 1).
- The `lsusb` smoke output (step 2).
- The `pio run` build summary tail (step 4).
- The `esptool ... write_flash` transcript tail (step 5).
- The full captured serial log including `Start T-Dongle-S3 LED
  example` (step 6).
- The audit-log contents at `${WORKDIR}/.substrate-ssh.log` from
  the run.
- A one-line note on the visual LED check (step 7).
