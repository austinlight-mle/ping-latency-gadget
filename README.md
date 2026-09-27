# Ping Gadget

A tiny always-on-top Windows gadget that shows ping latency and up/down throughput, and lets you switch the default gateway between your routers (restarting Astrill VPN along the way).

```
Time=250ms TTL=105
Up=1.5Mbps  Down=2.5Mbps   [Router 2 ▾]
```

## Build

Run `build.cmd`. It uses the C# compiler that ships with Windows (.NET Framework 4.x), so no SDK is needed. Output: `bin\PingGadget.exe`.

## Use

- Drag anywhere on the gadget to move it; the position is remembered.
- Right-click → **Settings** / **Close**.
- Pick a router in the dropdown to make it the gateway. The app:
  1. turns Astrill OFF by pressing the ON/OFF switch in its window (works while the window is visible, minimized or closed to the tray; only if "Toggle Astrill VPN" is checked),
  2. sets the adapter's gateway (the adapter whose subnet contains the router IP; it must use a static IP),
  3. re-points any leftover routes from the old router to the new one (e.g. Astrill's VPN-server route),
  4. turns Astrill back ON and waits for the VPN to reconnect. This happens even if the gateway change fails.

  The whole switch is limited by **Stop waiting for a router switch after N seconds** (Settings → General, default 60). On a dead or weak router Astrill may never reconnect; when time runs out the gadget shows "Switch timed out" or "VPN not reconnected", re-enables the dropdown, and auto-switch moves on. Astrill is left ON, still trying to connect.

  Astrill is left alone when it is not running, when it is already OFF, or when the OFF click doesn't take effect. Only if it is connected but its switch can't be found (e.g. a future Astrill UI change) does the app fall back to closing Astrill and starting it again with `/autostart`.
- **Auto-switch** (Settings → Ping): when the ping has failed continuously for X seconds, the gadget switches to the next router in the list, waits another X seconds, and keeps cycling until a ping succeeds. The countdown restarts after each switch, so allow enough time for Astrill to reconnect.
- Up/Down is the live throughput of the physical adapter (like Task Manager), not a speed test.

The app runs as administrator (required to change the gateway). "Run at Windows start" creates a logon scheduled task so it starts elevated without a UAC prompt.

Settings live in `%APPDATA%\PingGadget\settings.ini`.
