# Elite Series 2 configuration protocol on macOS

This builds on the reverse engineering in [lemonxah/xbelite2](https://github.com/lemonxah/xbelite2) (Linux, firmware 5.17) and the Windows Xbox Accessories USB captures in its `dumps/` folder. Everything marked *verified* was checked against a real controller (firmware 5.22.16.0) connected to a Mac. Where this document disagrees with upstream's `docs/protocol.md`, the captures and hardware tests below win.

A third source is the Windows Xbox Accessories app itself (package Microsoft.XboxDevices 2506.2505.28001.0, the build the captures came from) and the Elite Series 2 firmware 5.22.16.0 image it ships. Rows marked "app code" cite the virtual address of the function in `Devices.App.dll` (image base 0x180000000) that writes or reads the byte, and rows marked "firmware" cite the function in the firmware image loaded at 0x10027000. These are read from the decompiled code and are not hardware tested unless the row says so. The full evidence, with excerpts and the commands to reproduce it, is in the research notes that accompany this work (`findings.md`).

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

The Accessories app builds these as GIP message 0x0D with class GipStandardLatency (0x1002) through Windows' `LegacyGipGameControllerProvider` (app code, `MessageRequest` constructor stub 0x180c203b0 and its callers). The driver turns that into command byte 0x4D on the wire.

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

Byte 0 of every page is the format version, major in the high nibble and minor in the low: 0x10 is version 1.0 and 0x11 is version 1.1 (app code 0x180c27e04, firmware slot templates). The app writes 0x11 when the controller firmware is 5.21.3242.0 or newer and 0x10 below that (app code 0x180c21b78 compares the firmware with 5.21.3242.0). It decides by firmware, not by the page it read, so any save on current firmware writes 0x11 to all four pages. The 5.11.3113.0 firmware image's templates start with 0x10 and the 5.22.16.0 image's with 0x11. A 1.0 curves page is 28 bytes, a 1.1 curves page is 43 bytes (app code 0x180e9fc08 allocates 0x1c or 0x2b); the curves deserializer derives the version from the size it gets back. The mapping page is 56 bytes in both versions. The app's version gate covers only curves bytes 28-42 (sticky inputs and the Adaptive Controller's extra inputs) and the Adaptive mouse flags in mapping byte 52 bits 1-5; swap triggers (byte 52 bit 0) and the keyboard flags in bytes 52-55 are written in both versions.

### Mapping page (56 bytes)

Bytes 1-18 hold one output code per input, in this order: P1, P2, P3, P4, A, B, X, Y, D-pad up, down, left, right, LB, RB, LS click, RS click, LT, RT (app code, offset table in 0x180e9b104). The codes are the GIP button bit numbers where one exists:

| Code | Meaning | Source |
|---|---|---|
| 0x00 | unmapped | capture |
| 0x01 | Shift | capture |
| 0x02, 0x03 | Menu, View | app code 0x180e9b104, firmware 0x1004ed10 |
| 0x04-0x0F | A, B, X, Y, D-pad up/down/left/right, LB, RB, LS click, RS click | capture |
| 0x10, 0x11 | LT, RT. The firmware reports the trigger at 1023 while the input is held. | app code 0x180e9b104, firmware 0x1004ed10 |
| 0x12-0x19 | left stick up, down, left, right, then right stick up, down, left, right, pushed to full deflection | firmware tables 0x1004f050 and 0x1004f058 |
| 0x1A-0x1D | paddle outputs P1-P4 (sets the paddle bit in the extended report) | firmware 0x1004ed10 |
| 0x40 and up | special outputs of the Adaptive Controller, not used for the Elite 2 | app code, not traced |

When the input's keyboard flag (bytes 52-55 below) is set, the byte holds a HID keyboard usage instead of a code.

Layout:

| Bytes | Meaning | Source |
|---|---|---|
| 0 | format version, 0x10 or 0x11 | app code 0x180c27e04, firmware templates |
| 1-4 | paddle outputs: P1 upper right, P2 lower right, P3 upper left, P4 lower left | verified |
| 5-8 | A, B, X, Y outputs | capture |
| 9-16 | D-pad up/down/left/right, LB, RB, LS, RS outputs | capture |
| 17, 18 | LT, RT: 0x00 keeps the analog trigger, otherwise a code from the table above or a HID keyboard usage when the trigger's keyboard flag is set | capture, app code 0x180e9aeac |
| 19-27 | keyboard modifier nibbles, one byte per pair of inputs: 19 = P1 and P2, 20 = P3 and P4, 21 = A and B, 22 = X and Y, 23 = D-pad up and down, 24 = left and right, 25 = LB and RB, 26 = LS and RS, 27 = LT and RT. The first input of the pair is the low nibble. | app code 0x180c20bf4 and 0x180c215cc, firmware 0x1004ec42 |
| 28-31 | rumble scale 0-100: left grip, right grip, left trigger, right trigger in the app's own naming. This is the mirror image of upstream's order (right grip, left grip, RT, LT); one hardware test settles it. | app code 0x180e9d0b4 with the JSON names `LeftRumbleMotor`, `RightRumbleMotor`; upstream |
| 32-33 | LT (max, min) for the hair trigger lock in the full travel position. Max is the travel at which the trigger reads full, min the travel below which it reads zero. 0xFF and 0x00 by default. | app code 0x180e9d0b4, firmware 0x1005078c, capture |
| 34-35 | LT (max, min) for the half lock position. The app writes a copy of 32-33. | app code 0x180e9d0b4, firmware 0x1005078c |
| 36-37 | LT (max, min) for the short lock position. The app writes 0, 0. | app code 0x180e9d0b4, firmware 0x1005078c |
| 38-43 | RT, same layout as 32-37 | app code 0x180e9d0b4, firmware 0x1005078c |
| 44 | Xbox button brightness, 0-100 | verified |
| 45 | 0xFF default colour, 0x00 custom | capture |
| 46-48 | Xbox button RGB | verified (slot 1 stores 00 FF 00 and shows green) |
| 49-50 | brightness, 0-100, of two more LED channels (channel 2 at 49, channel 1 at 50), most likely the profile indicator lights. The app derives both from the Xbox button brightness; 100 maps to 0x30. | firmware 0x10050850, app code 0x180e9a484 |
| 51 | written by the app from a value its caller passes in, 0 in every capture; meaning not recovered | app code 0x180e9a484 |
| 52-55 | 32-bit little-endian flag word. Bit 0 swap triggers. Bits 1-5 Adaptive Controller mouse settings. Bits 6-13 keyboard flags for the Adaptive Controller's extra inputs. Bits 14-31 keyboard flags for bytes 1-18: bit 14 is byte 1 (P1), bit 31 is byte 18 (RT). Byte 55 bit 7 (0x80) is therefore RT as a keyboard key and bit 6 (0x40) is LT. | app code 0x180e9b104 and 0x180e9aeac, firmware 0x1004f5dc, capture |

The Accessories default for paddles is P1 B, P2 Y, P3 A, P4 X (`05 07 04 06`).

The firmware stores each byte of the trigger pairs as a 10-bit value, `b * 4 + (b >> 6)`, and the app stores its 0-1023 values as `v >> 2` (app code 0x180e991f4). If max is not above min the firmware repairs the pair (firmware 0x1005078c): when min is below 1023 it raises max to min + 1; when min is 1023 and max is 0 it resets the pair to max 1023, min 0; otherwise it lowers min to max - 1. So the (0, 0) pair the app writes for the short lock position makes that position an on/off switch. If the app finds max below min it writes 0xFF, 0x00 instead. The Windows "triggers 67%" capture, which set bytes 32, 34, 38 and 40 to 0xAB and left 33, 35, 39 and 41 at 0, is max 67% with min 0 written to the full and half positions of both triggers, which is exactly what the app's serializer does. Upstream's reading of bytes 34-35 and 40-41 as stick saturation does not match either the app or the firmware.

A Shift button is code 0x01 in **both** the normal and shift mapping pages. Upstream's description, which removes the button from the 9-16 array, doesn't match the captures.

A remapped paddle reports its own paddle bit as well as the button it is mapped to. Pressing the upper-right paddle on a slot where it's mapped to RB gives `RB P1` (verified).

### Keyboard keys and modifiers

Any of the 18 inputs can send a keyboard key. The input's byte holds the HID keyboard usage, its keyboard flag bit in bytes 52-55 is set, and its modifier nibble in bytes 19-27 holds the modifier set. The firmware puts the usage into the keyboard report and ORs the nibble into the report's modifier byte (firmware 0x1004ed10), so the nibble uses the HID modifier bits: Ctrl 0x1, Shift 0x2, Alt 0x4, Windows 0x8. The bit values are inferred from the order of the app's `KeyboardMappingModifier` names and the HID convention; the layout is read from the code. The existing capture, F on a trigger with 0x80 at byte 55, is RT as a keyboard key with no modifier.

### Swap sticks and swap triggers

Swap triggers is bit 0 of byte 52 with bytes 17 and 18 set to 0. The app sets it when LT is mapped to RT and RT to LT (app code 0x180e9aeac), and the firmware swaps the trigger index before applying the trigger ranges (firmware 0x100505da).

Swap sticks lives in the curves page: byte 27 bit 2 swaps the X axes and bit 3 swaps the Y axes between the sticks (app code 0x180e9fc08 with the JSON names `SwapThumbsticksXAxes` and `SwapThumbsticksYAxes`, firmware 0x10050594). The app's single swap toggle should set both, 0x0C. The stick clicks are not swapped; they are ordinary button mappings.

### Curves page (43 bytes)

| Bytes | Meaning | Source |
|---|---|---|
| 0 | format version | app code 0x180c27e04 |
| 1-24 | LX, LY, RX, RY curves, six bytes each: three (x, y) points, 0-255. Linear is `2b 2b 7f 7f bf bf`. The app always writes point 1 as (0x2b, 0x2b) and takes points 2 and 3 from the user's two handles. | capture, app code 0x180e9fc08 |
| 25-26 | one byte per stick that the firmware's own setting path calls rotation; the app writes 0 for the Elite 2 | firmware 0x1004f5dc, inferred |
| 27 | bit 0 inverts left Y, bit 1 inverts right Y, bit 2 swaps the X axes, bit 3 swaps the Y axes, bits 4-5 left stick mode, bits 6-7 right stick mode | capture, app code 0x180e9fc08, firmware 0x10050594 and 0x1005074e |
| 28-30 | sticky (toggle) inputs, one bit per input in mapping byte order: byte 28 bits 0-7 are P1, P2, P3, P4, A, B, X, Y; byte 29 bits 0-7 are D-pad up, down, left, right, LB, RB, LS, RS; byte 30 bits 0-1 are LT, RT. A set bit makes the input toggle its output. The app serializes all 18 bits, but the firmware applies the toggle only to the 16 inputs of mapping bytes 1-16: its toggle loop stops at 16 (0x1004fe34, the only caller of the toggle helper 0x10050b34) and the trigger bits of the input mask come straight from the range processing (0x1004e89e). The LT and RT bits are therefore written but not acted on by the firmware path traced. Written only in version 1.1. | app code 0x180e9fc08, firmware 0x1004f5dc, 0x1004fe34, 0x1004e89e |
| 31-38 | output codes of the Adaptive Controller's eight extra inputs, 0 on the Elite 2 | app code 0x180c25984 |
| 39-42 | modifier nibbles for those extra inputs, 0 on the Elite 2 | firmware 0x1004ec42 |

The stick mode in byte 27 is the app's `LeftThumbstickRadial` and `RightThumbstickRadial` property, 0, 1 or 2 (app code 0x180e9fb7c and the JSON reader 0x180c36a0c). In the firmware, mode 0 applies the curve to the stick's deflection magnitude and scales both axes by the result, mode 1 applies the curve to each axis on its own, and mode 2 is a second magnitude variant (firmware 0x1004ea50). The names of the three values are inferred from that code. The default is 0.

When the Accessories app inverted the right stick, it changed only the normal-layer curves page (0x21), not 0x27. Write stick settings to both layers only when they change.

How the firmware applies a curve (firmware 0x10050612): each byte becomes a 15-bit value, `b * 128 + b / 2`. Points 2 and 3 are then placed relative to point 1, `x2' = x1 + x2 * (32767 - x1) / 32767` and the same for y and for point 3, and the output is piecewise linear through (0, 0), point 1, point 2', point 3' and (32767, 32767). So the second and third points are fractions of the range above the first point, not absolute positions. A dead zone encoded as a first point (x, 0) still works, but it compresses the rest of the curve into the remaining range.

Preset shapes. The app does not write its preset constants directly. Before writing a curves page the constructor calls a normaliser with mode 1 (app code 0x180e9fdec calls 0x180c27e4c, then 0x180c27f04). It rebuilds the two model points as a legacy point set whose id is `1000 * (x1 % 10) + (x2 % 10)` (0x180bf8c90 with the constants at 0x1807fecc0 and 0x1807fec20), maps the id-tagged preset constants onto the legacy preset constants (0x180c283ec) and looks the id up in a 41-entry table (0x180c28980: one default plus four presets with ten intensity steps each, 0x180c280fc and 0x180c28148). The table pairs each legacy point set with the new-format points that go on the wire, written as `v * 2 >> 8` (0x180e9fad4). A miss falls back to the new default (0x3fff, 0x3fff, 0x5fbf, 0x5fbf), which is how the Default preset produces the captured page. The names come from the metadata's field order (Delayed, Aggressive, Instant, Smooth, which the UI calls Slow start, Fast start, Instant, Smooth) and are inferred; the bytes are the intensity 4 entries that the preset constants select. Only Default has been captured:

| Preset | Bytes 1-6 of each axis |
|---|---|
| Default | `2b 2b 7f 7f bf bf` |
| Slow start | `2b 2b 3f 3f da 8d` |
| Fast start | `2b 2b 3f 3f 8c c5` |
| Instant | `2b 2b 3f 3f 3f 68` |
| Smooth | `2b 2b 8c 8c d8 9c` |

Each preset has ten intensity steps in the table; the app's curve slider moves between them, so the Elite 2 pages the app writes only ever hold one of the 41 table entries.

## Input

0x20 extended report (47-byte payload):

- 0-1: buttons
- 2-5: LT and RT, 0-1023
- 6-13: sticks, i16
- 14: paddles. Bit 0 P1 upper right, bit 1 P2 lower right, bit 2 P3 upper left, bit 3 P4 lower left (verified).

The triggers and sticks in this report are what games get: the active profile's trigger range, dead zones and curves are already applied. The 0x0C report carries the same fields as the physical positions (verified on 5.22.16.0, profile 3 with a 30% left trigger range, a 30% left stick dead zone and Instant curves). Raw LT 151 came through 0x20 as 499 and raw 319 as 1023, the left stick read 0 in 0x20 up to about 30% raw deflection, and the unchanged right trigger matched exactly. macOS's own driver, with EliteForge closed, showed the same processed values.

The 0x0C report has the same layout for bytes 0-14, with the physical trigger and stick positions before the profile's settings. It carries the active slot in payload byte 15. Byte 16 holds the hair trigger lock positions, `(RT << 2) | LT`, with 0 = full travel, 1 = half, 2 = short (verified on Profile 0 (Default) on macOS, and in the Windows calibration capture with Profile 1 active). The locks are physical switches with no software setting. The controller detects their position and scales the shorter travel so a full pull still reports 1023. The same position also selects which (max, min) pair of the mapping page applies to the trigger.

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

## Turning the controller off

Not recovered. In `Devices.Abstraction.dll` the GIP controller's `IPowerApi.TurnOffDevice` (vtable 0x18009c650 slot 7, function 0x18006d870) throws HRESULT 0x80070032, not supported, and `SendPowerResetMessage` (slot 6, 0x18006d810) forwards to Windows' `LegacyGipGameControllerProvider`, so the bytes are built inside Windows. None of the eleven GIP messages the app constructs itself uses command 0x05. Linux drivers send command 0x05 with payload 0x04 to turn a GIP controller off; that is not verified here.

## Still unknown

Recovered from the app and firmware code but not yet tested on hardware: the trigger min and max pairs, keyboard keys with modifiers on buttons and paddles, triggers as targets, sticky inputs, swap sticks and swap triggers, the preset point values, and the firmware's relative placement of curve points 2 and 3.

These still need a hardware test or a new Windows capture:

- Which grip motor bytes 28 and 29 drive. The app names byte 28 the left rumble motor; upstream and EliteForge treat it as the right one. Setting one byte to 0 and rumbling settles it.
- The bytes behind the app's Turn off controller button (a Windows USB capture while pressing it).
- The meaning of byte 51 and of the short-lock pairs 36-37 and 42-43 beyond the firmware's on/off repair.
- The three stick mode values in curves byte 27 bits 4-7, and whether the Elite 2 pages in the Accessories app ever offer sticky inputs, Menu and View (codes 0x02 and 0x03) or paddle outputs (0x1A-0x1D).
- The exact bytes of the Slow start, Fast start, Instant and Smooth presets, derived above from the app's constants but not captured.
