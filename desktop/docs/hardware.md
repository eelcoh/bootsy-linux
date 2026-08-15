# Desktop hardware notes

Bootsy includes firmware updates, Thunderbolt authorization, fingerprint
support, hybrid-GPU switching, screen rotation, power profiles, printing, and
driverless scanning. Hardware support still depends on device firmware and the
kernel driver.

- Check firmware with `fwupdmgr get-updates`.
- Check Bluetooth after resume with `bluetoothctl show` and `journalctl -u bluetooth`.
- Use `powerprofilesctl` for power modes. Battery charge thresholds are not
  forced globally because their sysfs interfaces and safe limits vary by model.
- Test camera/microphone/screen sharing in Zen; the PipeWire and portal stacks
  are installed for Niri, Sway, and COSMIC.
