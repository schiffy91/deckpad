"""Observe the independent Linux input stack while driving the emulated Deck."""
import fcntl
import os
import select
import struct
import sys
import time
from pathlib import Path

from evdev import InputDevice, ecodes as E, list_devices

product = int(sys.argv[1], 16)
fixture = Path("/tmp/shared/deckpad-input.bin")
applied = fixture.with_suffix(".bin.applied")
sequence = int(applied.read_text() or "0") if applied.exists() else 0


def drive(*, pressed=False, touch=False, x=0, y=0, scroll=0):
    global sequence
    sequence = (sequence + 1) % 256
    report = bytearray(64)
    report[:4] = bytes([1, 0, 9, 64])
    report[8] = 0x80 if pressed else 0  # A
    report[10] = (0x18 if touch else 0) | (4 if pressed else 0)  # both pads, right click
    struct.pack_into("<hhh", report, 18, scroll, x, y)
    report[63] = sequence
    temporary = fixture.with_suffix(".new")
    temporary.write_bytes(report)
    temporary.replace(fixture)
    until = time.monotonic() + 3
    while time.monotonic() < until:
        if applied.exists() and applied.read_text() == str(sequence):
            return
        time.sleep(0.01)
    raise AssertionError("the emulated physical Deck did not apply the input")


def desktop_nodes():
    nodes = []
    mouse = keyboard = False
    for name in list_devices():
        dev = InputDevice(name)
        caps = dev.capabilities()
        rel = caps.get(E.EV_REL, [])
        keys = caps.get(E.EV_KEY, [])
        pointer = E.REL_X in rel and E.REL_WHEEL in rel and E.BTN_LEFT in keys
        typing = E.KEY_ENTER in keys and E.KEY_UP in keys
        if (dev.info.vendor, dev.info.product) == (0x28de, product) and (pointer or typing):
            nodes.append(dev)
            mouse |= pointer
            keyboard |= typing
        else:
            dev.close()
    if mouse and keyboard:
        return nodes
    for dev in nodes:
        dev.close()
    return []


until = time.monotonic() + 15
while not (devices := desktop_nodes()):
    assert time.monotonic() < until, "Linux did not register both desktop input capabilities"
    time.sleep(0.1)


def expect_events(expected):
    # Preserve order within each event code. Separate input nodes can wake in either order.
    got = {}
    deadline = time.monotonic() + 2
    quiet = None
    while time.monotonic() < deadline:
        if got == expected:
            quiet = quiet or time.monotonic()
            if time.monotonic() - quiet >= 0.15:
                return
        else:
            quiet = None
        ready, _, _ = select.select(devices, [], [], 0.03)
        for device in ready:
            for event in device.read():
                if event.type in (E.EV_REL, E.EV_KEY) and (event.type, event.code) != (E.EV_REL, E.REL_WHEEL_HI_RES):
                    got.setdefault((event.type, event.code), []).append(event.value)
    raise AssertionError(f"desktop events {got}, expected {expected}")


def edges(value):
    return {(E.EV_KEY, E.KEY_ENTER): [value], (E.EV_KEY, E.BTN_LEFT): [value]}


def gesture():
    drive(touch=True, x=-4096)
    expect_events({})
    drive(touch=True, x=-3584, y=256, scroll=2048)
    expect_events({(E.EV_REL, E.REL_X): [4], (E.EV_REL, E.REL_Y): [-2], (E.EV_REL, E.REL_WHEEL): [1]})
    drive(pressed=True)
    expect_events(edges(1))
    drive()
    expect_events(edges(0))


drive()
time.sleep(0.2)
for device in devices:
    if select.select([device], [], [], 0)[0]:
        list(device.read())  # discard the original SDL fixture's release
gesture()  # A desktop with no userspace controller client at all.
if len(sys.argv) > 2 and sys.argv[2] == "reconnected":
    sys.exit(0)

raw_dir = next(p for p in Path("/sys/class/hidraw").glob("hidraw*")
               if f":000028DE:{product:08X}" in (p / "device/uevent").read_text().upper())
raw = os.open("/dev/" + raw_dir.name, os.O_RDWR | os.O_NONBLOCK)


def setting(value, watchdog=True):
    report = bytearray(64)
    report[:9] = bytes([1, 0x87, 6, 9, value, 0, 71, int(watchdog), 0])
    # HIDIOCSFEATURE(64) on the x86_64 Linux VM host.
    fcntl.ioctl(raw, 0xc0404806, report)


drive(pressed=True)
expect_events(edges(1))
setting(0, watchdog=False)
expect_events(edges(0))
drive()
drive(touch=True, x=500, pressed=True)
expect_events({})
# Read until the same sample arrives in the gamepad stream while desktop input is quiet.
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    if select.select([raw], [], [], 0.2)[0]:
        data = os.read(raw, 64)
        if data[0] in (0x42, 0x45) and data[2] & 1 and struct.unpack_from("<h", data, 24)[0] == 500:
            break
else:
    raise AssertionError("gamepad input stopped during takeover")
os.write(raw, bytes([0x80, 0, 0, 0, 0x34, 0x12, 0, 0x78, 0x56, 0]))
setting(1)
expect_events({})  # inputs held across handoff stay released
drive()
gesture()
setting(0)
drive(pressed=True)
expect_events({})
drive()
time.sleep(3)
setting(0)  # SDL refreshes at this interval
time.sleep(2.2)
drive(pressed=True)
expect_events({})
drive()
time.sleep(3)
gesture()  # watchdog expiry without closing the raw device
setting(0, watchdog=False)  # reconnect must start in desktop mode
