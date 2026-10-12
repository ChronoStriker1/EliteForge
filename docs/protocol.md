# Elite Series 2 configuration protocol on macOS

This builds on the reverse engineering in [lemonxah/xbelite2](https://github.com/lemonxah/xbelite2) (Linux, firmware 5.17) and the Windows Xbox Accessories USB captures in its `dumps/` folder. Everything marked *verified* was checked against a real controller (firmware 5.22.16.0) connected to a Mac. Where this document disagrees with upstream's `docs/protocol.md`, the captures and hardware tests below win.

## Getting at the controller on macOS

macOS ships a DriverKit driver (`com.apple.gamecontroller.driver.XboxGamepad`) that owns the controller over USB: `XboxUSBDevice` on the device and `XboxEliteV2Gamepad` on interface 0. It exposes a HID device with only these reports:

| Report | Direction | Size | Use |
|---|---|---|---|
| 0x01 | out | 12 | rumble |
| 0x05 | out | 4 | LED |
| 0x07 | in | 5 | guide button |
| 0x20 | in | 17 | gamepad input |

There is no passthrough for the 0x4D vendor commands, so profiles can't be read or written through it.

Opening the device without root fails:

- `IOUSBHostObjectInitOptionsDeviceSeize`: Apple's driver refuses to close (`kIOReturnExclusiveAccess`).
- No options: exclusive open fails.

`IOUSBHostObjectInitOptionsDeviceCapture` works as root. It terminates the system driver and its interface clients. The exclusive open can fail for a few hundred milliseconds while they shut down, for the device and again for interface 0, so retry both. Destroying the captured `IOUSBHostDevice` resets the controller, and Apple's driver binds to it again.

Don't capture a controller that was just plugged in. On macOS 27.0.1, capturing while Apple's Xbox and HID drivers were still starting on a freshly connected controller caused a kernel panic (null dereference in `IOHIDFamily`). Wait a few seconds after arrival and call `IOServiceWaitQuiet` on the device first.

Wait about 3 seconds after a release before capturing again. Otherwise you can grab a device that is still re-enumerating, and its pipes fail on every read.

## Framing

The header is `[command] [options] [sequence] [length]`. The length is a LEB128 varint.

Options:

| Bits | Meaning |
|---|---|
| 0x0F | client ID |
| 0x10 | acknowledgement required |
| 0x20 | system (internal) message |
| 0x40 | first chunk |
| 0x80 | chunked |

A chunked frame has a second varint after the length. On the first chunk it holds the total size, and on later chunks the chunk's offset.

Acknowledgement:

```
01 20|client <seq> 09 00 <cmd> <opts & 0x2F> <received u16> 00 00 <remaining u16>
```

For example, the Accessories app acknowledges a 60-byte page reply with `01 20 5a 09 00 4d 00 3c 00 00 00 00 00`.

## Init

Sent once per capture. Don't re-send it on later HELLOs, except after the controller restarts its session. The reload at the end of a save does this: HELLOs keep coming while the gamepad itself goes quiet, and input stays dead until the init is sent again. Silence alone is not a restart. The gamepad's status frames (`03 20 ...`) come about once a second for roughly 10 s after an init, then every 20 s, the same as in the Windows captures (verified on 5.22.16.0). Treating the first long gap as a restart and re-sending init put the controller into a cycle of a re-init every 14 s, so EliteForge re-sends it only within 15 s of a save. After a save the reload (`05 20 .. 01 05`) is followed by about 2.4 s of silence, one re-init, and normal input.

```
05 20 01 01 00                power on
05 20 00 0f 06                Bluetooth -> USB. Fixed bytes: length byte 0x0F, one payload byte.
4d 10 02 02 07 00             extended input reports (paddles, active slot)
0a 20 03 03 00 01 14          LED on. Also starts the input stream: without it, no 0x20 reports arrive (verified).
06 20 04 02 01 00             auth done
0e 00 05 05 01 00 00 00 00    end LED override, so the Xbox button shows the active profile's colour again
```

The LED-on command forces the Xbox button to dim white, which earlier made the light look white-only. The final 0x0E mode-1 frame is the one the Accessories app sends after a colour preview.

The controller only sends input reports when something changes. With the sticks at rest it can stay silent indefinitely, so silence after init doesn't mean the init failed.

Encoding the second packet as a normal two-byte payload (`05 20 xx 02 0f 06`) leaves the controller re-announcing forever and never sending input. If every HELLO triggers a fresh init, the controller loops too, because the Bluetooth -> USB packet restarts it.

Send a keepalive every 2 seconds: `09 00 <seq> 09 00 0f 00 00 00 00 ff 00 eb` (rumble off). Skip it while a rumble test is running so it doesn't stop the motors early.

### Client 1: the virtual keyboard

On firmware 5.22, HELLO (`02 21 ...`) comes from client 1 and repeats every 504 ms. Identify it with `04 21 <seq> 00`. Its 177-byte chunked reply names the client `Windows.Xbox.Input.Chatpad` and carries a HID keyboard report descriptor. This is how the controller sends keyboard keys on Xbox and Windows. Once the chunks are ACKed correctly, client 1 stops announcing. The gamepad itself is client 0.

## Vendor commands (0x4D)

All configuration goes through these. Replies come from the controller's own sequence counter, so match them by sub-command and page, not by sequence.

Reply byte 1 is a status:

| Status | Meaning |
|---|---|
| 0x00 | OK |
| 0x80 | The page belongs to the active profile slot. Reads still return valid data. |

**Writes need Profile 0 (Default) active** (verified). With slot 1, 2 or 3 selected on the controller, unlock replies `03 80 <page of active slot>` and nothing can be written. Press the profile button until no light is on, then unlock replies `03 00`.

Commands:

| Command | Bytes | Reply |
|---|---|---|
| unlock / commit | `4d 10 s 01 03` | `03 00` |
| extended reports | `4d 10 s 02 07 00` | `07 00` |
| read page | `4d 10 s 03 02 <page> <size>` | `02 <status> <page> <size> <data>` |
| write page | `4d 10 s <3+n> 01 <page> <n> <data>` | `01 00 <page>` |
| read name | `4d 10 s 01 05` | `05 00 <32 bytes UTF-16LE>` |
| write name | `4d 10 s 21 04 <32 bytes UTF-16LE>` | `04 00` |

The Accessories app saves a slot in this order (verified working):

1. extended reports, then unlock, unlock
2. write normal mapping, shift mapping, normal curves, shift curves
3. extended reports, then unlock (this commits to flash)
4. read all four pages back
5. `05 20 s 01 05` (reload)

## Pages

| Slot | Normal mapping | Normal curves | Shift mapping | Shift curves |
|---|---|---|---|---|
| 1 | 0x20 | 0x21 | 0x26 | 0x27 |
| 2 | 0x22 | 0x23 | 0x28 | 0x29 |
| 3 | 0x24 | 0x25 | 0x2A | 0x2B |

Byte 0 of every page is 0x10 on a slot that has never been written and 0x11 once the Accessories app has saved it.

### Mapping page (56 bytes)

Each output byte holds a code:

| Code | Meaning |
|---|---|
| 0x00 | unmapped |
| 0x01 | Shift |
| 0x04-0x0F | A, B, X, Y, D-pad up/down/left/right, LB, RB, LS click, RS click |

Layout:

| Bytes | Meaning | Source |
|---|---|---|
| 0 | flags (0x10 blank, 0x11 saved) | hardware |
| 1-4 | paddle outputs: P1 upper right, P2 lower right, P3 upper left, P4 lower left | verified |
| 5-8 | A, B, X, Y outputs | capture |
| 9-16 | D-pad up/down/left/right, LB, RB, LS, RS outputs | capture |
| 17, 18 | LT, RT: 0x00 normal, otherwise a HID keyboard usage (0x09 = F) | capture |
| 19-27 | unknown, zero | |
| 28-31 | rumble scale: right grip (weak), left grip (strong), RT, LT; 0-100 | upstream |
| 32-33 | LT saturation, u16 LE with zero high byte: travel at which the trigger reads full. 0xFF full travel (default), lower values reach full sooner, 0x00 on/off. | upstream |
| 34-35 | Left stick saturation, u16 LE; preserved when changing trigger range. | upstream |
| 38-39 | RT saturation, same semantics as LT. | upstream |
| 40-41 | Right stick saturation, u16 LE; preserved when changing trigger range. | upstream |
| 44 | Xbox button brightness, 0-100 | verified |
| 45 | 0xFF default colour, 0x00 custom | capture |
| 46-48 | Xbox button RGB | verified (slot 1 stores 00 FF 00 and shows green) |
| 49-50 | unknown (0x30 0x30 by default) | |
| 55 | 0x80 when a trigger sends a keyboard key | capture |

The Accessories default for paddles is P1 B, P2 Y, P3 A, P4 X (`05 07 04 06`).

Trigger range uses [upstream xbelite2's saturation layout](https://github.com/lemonxah/xbelite2/blob/89ae1c5ed1dd20a56e3e9eb02830aac304ff53a7/gip/src/types.rs). The Windows "triggers 67%" capture changed all four low bytes (32, 34, 38, 40) to 0xAB, but that does not make the stick fields part of the trigger setting. EliteForge changes only 32-33 and 38-39, preserving each mapping page's stick saturation. This adopts upstream's interpretation; it is not a new Mac hardware verification.

A Shift button is code 0x01 in **both** the normal and shift mapping pages. Upstream's description, which removes the button from the 9-16 array, doesn't match the captures.

A remapped paddle reports its own paddle bit as well as the button it is mapped to. Pressing the upper-right paddle on a slot where it's mapped to RB gives `RB P1` (verified).

### Curves page (43 bytes)

| Bytes | Meaning |
|---|---|
| 0 | flags |
| 1-24 | LX, LY, RX, RY curves, six bytes each: three (x, y) points, 0-255. Linear is `2b 2b 7f 7f bf bf`. |
| 27 | bit 0 inverts left Y, bit 1 inverts right Y |

When the Accessories app inverted the right stick, it changed only the normal-layer curves page (0x21), not 0x27. Write stick settings to both layers only when they change.

## Input

0x20 extended report (47-byte payload):

- 0-1: buttons
- 2-5: LT and RT, 0-1023
- 6-13: sticks, i16
- 14: paddles. Bit 0 P1 upper right, bit 1 P2 lower right, bit 2 P3 upper left, bit 3 P4 lower left (verified).

The triggers and sticks in this report are what games get: the active profile's trigger range, dead zones and curves are already applied. The 0x0C report carries the same fields as the physical positions (verified on 5.22.16.0, profile 3 with a 30% left trigger range, a 30% left stick dead zone and Instant curves). Raw LT 151 came through 0x20 as 499 and raw 319 as 1023, the left stick read 0 in 0x20 up to about 30% raw deflection, and the unchanged right trigger matched exactly. macOS's own driver, with EliteForge closed, showed the same processed values.

The 0x0C report has the same layout for bytes 0-14, with the physical trigger and stick positions before the profile's settings. It carries the active slot in payload byte 15. Byte 16 holds the hair trigger lock positions, `(RT << 2) | LT`, with 0 = full travel, 1 = half, 2 = short (verified on Profile 0 (Default) on macOS, and in the Windows calibration capture with Profile 1 active). The locks are physical switches with no software setting. The controller detects their position and scales the shorter travel so a full pull still reports 1023.

## HELLO

The 28-byte payload holds:

| Bytes | Meaning |
|---|---|
| 0-7 | device ID |
| 8-9 | vendor ID |
| 10-11 | GIP product ID (0x0B02) |
| 12-19 | firmware, four u16 values (5.22.16.0 here) |
| 20-27 | hardware version |

## Calibration (0x1E)

Captured from the Accessories app's thumbstick and trigger calibration on Windows (firmware 5.22.16.0, app 2506.2505.28001.0). Requests and replies use command 0x1E with option 0x10 (needs ack), the same way as vendor requests. The controller doesn't need to be on the Default profile; the capture ran with Profile 1 active.

| Request | Reply | Meaning |
|---|---|---|
| `1e 10 s 02 0f T` | `0f 00 F T values` | read the calibration of target T |
| `1e 10 s 02 10 T` | `10 00 T` | start calibrating T |

T is a bit: 0x01 left stick, 0x02 right stick, 0x04 left trigger, 0x08 right trigger. Stick values are four u16 LE in raw 12-bit sensor units: X minimum, X maximum, Y minimum, Y maximum (left stick before: 849, 3233, 883, 3248). A trigger reply has a count byte (4) before its values: the sensor reading at rest, then at the end of the pull with the short, half and full hair trigger lock (left trigger before: 1070, 1353, 1896, 3341).

F is the controller's state, the same whatever target is read: 0x00 when no calibration is running, the target bit while one is (0x04 right after a left trigger start), and 0x10 on the read that ends a finished calibration. While a target is being calibrated its values read as zero; other targets read their stored values.

The Accessories app's sequence for each target:

1. Read T (F = 0x00), the stored values.
2. Start T. A trigger start took 0.8 s to be answered; a stick start, 40 ms.
3. The user moves the control. Sticks: 6 turns clockwise at the edge, 6 counter-clockwise, then a push up, right, down and left, then let go. Triggers: 12 full pulls and releases with the hair trigger lock on full, 12 on half, 12 on short. The app buzzes all four motors at 10 for about 300 ms (`09 00 s 09 00 0f 0a 0a 0a 0a ff 00 eb`) after each part, then once at 30 when all movement is done.
4. Read T again (F = 0x10). That ends the calibration and stores the new values: after a replug, on macOS, the stored values matched the last reads exactly. Two more buzzes at 30 follow.

EliteForge follows the same sequence and has calibrated the right stick on macOS this way: the final read came back with F = 0x10 and the values were stored (X 967-3283, Y 782-3331).

While a calibration runs, the target's processed values in the 0x20 report can stay still, so anything watching the movement has to read the raw 0x0C positions, which keep coming. An unfinished calibration survives a helper release and recapture, and also a USB replug, since the controller keeps running on its battery.

The controller decides when it has seen enough. A read after only 3 turns of the right stick, on macOS, came back with F = 0x02 and zeros, and the calibration kept running: reading doesn't end an unfinished one. There's no cancel in the capture and no command that writes values directly, so a calibration can only be replaced by running another one.

## Still unknown

These need new USB captures of the Windows Accessories app:

- swap sticks, and swap triggers
- trigger inner dead zone (stick dead zones are set through the curve: a first point of (x, 0) keeps output at zero up to x)
- the exact point values of the Aggressive, Instant, Delay and Smooth curve presets
- keyboard keys on buttons and paddles (only triggers are captured)
- bytes 19-27 and 49-50 of the mapping page
