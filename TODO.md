# To do

## The trackpad as a pointer without Steam on the host

Today the host needs Steam running for the Deck's trackpads to move a pointer
or type. Deck Pad presents one USB HID interface, the controller's own
(`src/ControllerUSB.btrc`), and its raw reports mean nothing to a desktop
until Steam Input translates them. Without Steam the kernel's `hid-steam`
makes a plain gamepad of it and nothing more. On 2026-11-21 the controller
attached to a host where Steam was not open, and the trackpad moved nothing.

Valve's own hardware has a fallback for this. The Deck's pad is three
interfaces, a keyboard, a mouse and the controller (`src/DeckPad.btrc` takes
all three from the kernel), and while no Steam client has switched it off the
pad itself moves the pointer and types ("lizard mode"). Steam switches the
fallback off when it takes the controller and it comes back when Steam lets
go. Deck Pad leaves that fallback out.

- [ ] Present a mouse and a keyboard interface beside the controller's, on
      every link (network, USB-C, Bluetooth), with the descriptors Valve's
      controller uses.
- [ ] While the fallback is on, turn the pad into their reports: right
      trackpad as pointer, its click and the triggers as buttons, left
      trackpad as scroll, and the keys the hardware sends for the face
      buttons and the D-pad. Take the mapping from what the Deck's own pad
      sends in that mode, read on the Deck, not from memory.
- [ ] Follow the host's feature reports that switch the fallback off and on,
      and its watchdog: Steam must keep saying off, and silence turns it
      back on.
- [ ] Tests: the unit suite for the mapping and the switch; `vm-links` with a
      host that has no Steam, where the kernel's own HID drivers move a
      pointer; and the same host with a client that switches the fallback
      off, where nothing arrives twice.
- [ ] On the real machines: a pointer with Steam closed on the host, and no
      second pointer with Steam open.
- [ ] Then remove what stands in for it in `/etc/nixos`: the udev rule and
      the `steam-for-controller` user unit in
      `config/pkgs/gaming/deckpad/default.nix`, which start Steam in the
      background when the controller attaches. That rule has not been seen
      working on a real attach yet.
