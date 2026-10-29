# Ping Gadget

A tiny always-on-top Windows gadget that shows ping latency and up/down throughput, and lets you switch the default gateway between your routers (restarting Astrill VPN along the way).

For the macOS version, see [macos/README.md](macos/README.md).

```
Time=250ms TTL=105
Up=1.5Mbps  Down=2.5Mbps   [Router 2 ▾]
```

## Download

Get the latest version from [Releases](https://github.com/austinlight-mle/ping-latency-gadget/releases/latest):

| | File |
|---|---|
| Windows | `PingGadget.exe` |
| Mac, any (recommended) | `PingGadget-macOS.zip`: universal, Intel and Apple silicon |
| Mac, as a disk image | `PingGadget-macOS.dmg`: universal, drag to Applications |
| Mac with Apple silicon (M1 and later) | `PingGadget-macOS-AppleSilicon.zip`: macOS 11+, smallest |
| Mac with Intel | `PingGadget-macOS-Intel.zip`: macOS 10.13+ |

The build of the newest commit on `main` is always available as the [latest-build](https://github.com/austinlight-mle/ping-latency-gadget/releases/tag/latest-build) pre-release.

## Build

Run `build.cmd`. It uses the C# compiler that ships with Windows (.NET Framework 4.x), so no SDK is needed. Output: `bin\PingGadget.exe`.

## Releases

The version lives in the `VERSION` file (three numbers, e.g. `1.2.0`) and is stamped into both apps. Every push to `main` makes GitHub Actions ([.github/workflows/release.yml](.github/workflows/release.yml)) build the Windows and macOS apps. If no release exists yet for that version, it publishes release `v<version>` with all the downloads above. If one already exists, it replaces the `latest-build` pre-release with this build instead, so every push can be downloaded. To publish a numbered release, bump `VERSION` and push.

The macOS app is signed with the same certificate as on the developer's Mac when the repository has the `MACOS_SIGNING_P12` and `MACOS_SIGNING_P12_PASSWORD` secrets; see [macos/README.md](macos/README.md#code-signing).

## Use

- Drag anywhere on the gadget to move it; the position is remembered.
- Right-click → **Disconnect Internet** / **Settings** / **Close**.
- Pick a router in the dropdown to make it the gateway. The app:
  1. turns Astrill OFF by pressing the ON/OFF switch in its window (works while the window is visible, minimized or closed to the tray; only if "Toggle Astrill VPN" is checked),
  2. sets the adapter's gateway (the adapter whose subnet contains the router IP; it must use a static IP),
  3. re-points any leftover routes from the old router to the new one (e.g. Astrill's VPN-server route),
  4. turns Astrill back ON and waits for the VPN to reconnect. This happens even if the gateway change fails.

  The whole switch is limited by **Stop waiting for a router switch after N seconds** (Settings → General, default 60). On a dead or weak router Astrill may never reconnect; when time runs out the gadget shows "Switch timed out" or "VPN not reconnected", re-enables the dropdown, and auto-switch moves on. Astrill is left ON, still trying to connect.

  Astrill is left alone when it is not running, when it is already OFF, or when the OFF click doesn't take effect. Only if it is connected but its switch can't be found (e.g. a future Astrill UI change) does the app fall back to closing Astrill and starting it again with `/autostart`.
- **Auto-switch** (Settings → Ping): when the ping has failed continuously for X seconds, the gadget switches to the next router in the list, waits another X seconds, and keeps cycling until a ping succeeds. The countdown restarts after each switch, so allow enough time for Astrill to reconnect.
- Up/Down is the live throughput of the physical adapter (like Task Manager), not a speed test.
- **Disconnect Internet** cuts the internet off by moving the router-facing adapter to `10.10.10.X` / `255.255.255.0` with no gateway and no DNS (X is the last number of its current IP, e.g. `192.168.1.162` → `10.10.10.162`). The menu item then reads **Connect Internet**, which puts the original IP, mask, gateway and DNS back. While disconnected the gadget shows "Internet off", stops pinging, and locks the router dropdown (it shows the router that Connect will restore).

  The original settings are saved to `%APPDATA%\PingGadget\offline.ini` before anything changes, so Connect still works after closing the app or rebooting. If you restore the IP by hand instead, the app notices and forgets the saved copy. Like router switching, it needs a static IP. Astrill isn't turned off or on by this.

The app runs as administrator (required to change the gateway). "Run at Windows start" creates a logon scheduled task so it starts elevated without a UAC prompt.

Settings live in `%APPDATA%\PingGadget\settings.ini`.
