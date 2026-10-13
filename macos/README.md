# Ping Gadget for macOS

The macOS version of Ping Gadget. It has the same features as the Windows app: a tiny always-on-top gadget that shows ping latency and up/down throughput, and lets you switch the default gateway between your routers (toggling Astrill VPN along the way).

```
Time=250ms TTL=105
Up=1.5Mbps  Down=2.5Mbps   [Router 2 ▾]
```

## Build

Run `./build.sh` on a Mac with Xcode installed (it uses Xcode's Swift toolchain, which can build for Intel Macs). Output:

- `bin/PingGadget.app`: one universal app for **Intel Macs on macOS 10.13 (High Sierra) or later** and **Apple silicon Macs on macOS 11 or later**. It carries its own copy of the Swift runtime for macOS versions that don't include one.
- `bin/PingGadget-macOS.zip`: the same app, zipped so its signature survives copying. **Copy this zip to other Macs**, not the `.app` folder. Copying a bare `.app` through chat apps, some cloud drives or a FAT-formatted USB stick can strip its permissions or signature, and macOS then says it is "damaged".

## Install on another Mac

1. Unzip `PingGadget-macOS.zip` and drag `PingGadget.app` to `/Applications`.
2. Open it. The app is signed but not notarized by Apple (that needs a paid Apple Developer ID), so the first time macOS blocks it:
   - **macOS 15 Sequoia or later:** after the warning, open System Settings → Privacy & Security, scroll down, click **Open Anyway** next to "PingGadget", and confirm.
   - **macOS 14 or earlier:** Control-click (right-click) the app → **Open** → **Open**.
3. If macOS says the app **is damaged**, or neither option appears, run this once in Terminal and open it again:

   ```sh
   xattr -dr com.apple.quarantine /Applications/PingGadget.app
   ```

After the first launch it opens normally.

## Use

- Drag anywhere on the gadget to move it; the position is remembered.
- Right-click (or Control-click) → **Settings** / **Pin to menu bar** / **Close** (and **Cancel switch** while a switch is running).
- **Pin to menu bar** hides the gadget and shows the readings in the menu bar instead, e.g. `250ms  ↑1.5Mbps  ↓2.5Mbps`. Click them for the routers, Settings, **Unpin from menu bar** (back to the floating gadget) and Close. The mode is remembered.
- Pick a router in the drop-down to make it the gateway. The app:
  1. turns Astrill OFF with its **Toggle ON/OFF** menu command (works while the Astrill window is visible, hidden in the menu bar or minimized; only if "Toggle Astrill VPN" is checked),
  2. sets the Router of the network service whose subnet contains the router IP (System Settings → Network → *service* → Details → TCP/IP; it must be set to **Configure IPv4: Manually**),
  3. re-points any leftover routes from the old router to the new one (e.g. Astrill's VPN-server route),
  4. turns Astrill back ON and waits for the VPN to reconnect. This happens even if the gateway change fails.

  The whole switch is limited by **Stop waiting for a router switch after N seconds** (Settings → General, default 60). On a dead or weak router Astrill may never reconnect; when time runs out the gadget shows "Switch timed out" or "VPN not reconnected", re-enables the drop-down, and auto-switch moves on. Astrill is left ON, still trying to connect.

  Astrill is left alone when it is not running, when it is already OFF, or when the toggle doesn't take effect. Only if it is connected but its toggle can't be reached does the app fall back to quitting Astrill and starting it again with `/autostart`.
- **Auto-switch** (Settings → Ping): when the ping has failed continuously for X seconds, the gadget switches to the next router in the list, waits another X seconds, and keeps cycling until a ping succeeds. The countdown restarts after each switch, so allow enough time for Astrill to reconnect.
- Up/Down is the live throughput of the network adapter (like Activity Monitor), not a speed test.

## Permissions

- **Administrator rights (once).** Changing the gateway and routes needs root. Instead of running the whole app as root (as the Windows app runs as administrator), the first time it's needed macOS asks for your password and the app installs a small helper script, `/Library/PrivilegedHelperTools/com.pinggadget.helper`, and a rule in `/etc/sudoers.d/pinggadget` that lets your account run that one script without a password. After that, switches never prompt, including automatic switches. The helper only runs `networksetup -setmanual` and `route` with validated arguments.
- **Accessibility** (System Settings → Privacy & Security → Accessibility → Ping Gadget). Needed to press Astrill's ON/OFF toggle. Without it, the app falls back to quitting and restarting Astrill. An ad-hoc signed app gets a new identity on every rebuild, so after rebuilding, remove Ping Gadget from that list and add it again.

**Open at login** (Settings → General) adds `~/Library/LaunchAgents/com.pinggadget.launcher.plist`.

Settings live in `~/Library/Application Support/PingGadget/settings.ini` (same format as the Windows `settings.ini`).

## Uninstall

```sh
sudo rm /etc/sudoers.d/pinggadget /Library/PrivilegedHelperTools/com.pinggadget.helper
rm -f ~/Library/LaunchAgents/com.pinggadget.launcher.plist
rm -rf ~/Library/Application\ Support/PingGadget /Applications/PingGadget.app
```

## Differences from the Windows version

| | Windows | macOS |
|---|---|---|
| Gateway change | WMI `SetGateways` on the adapter | `networksetup -setmanual` on the network service |
| Route moves | IP Helper API | `route` via the helper |
| Astrill OFF/ON | posts clicks to the switch in its window, reads the switch's pixels | presses its **Toggle ON/OFF** menu item (or clicks the switch when its window is on screen); tells ON from OFF by its VPN engine process and VPN routes |
| Elevation | runs as administrator; "Run at Windows start" uses a scheduled task | a root helper allowed through sudo; "Open at login" uses a LaunchAgent |
| Font size | points at 96 dpi | scaled by 4/3 so the same number looks the same size |
