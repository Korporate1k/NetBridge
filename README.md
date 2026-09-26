# NetBridge for Windows

Sends all of a Windows PC's traffic (TCP and UDP, IPv4 and IPv6) through the **NetBridge** app running on your iPhone, as a system-wide VPN. The phone relays the traffic over its own connection.

## Download

Get the latest zip from **[Releases](https://github.com/Korporate1k/NetBridge/releases)**:

| File | For |
|---|---|
| `NetBridge-win-x64.zip` | Windows 10/11 on Intel/AMD PCs |
| `NetBridge-win-arm64.zip` | Windows 11 on ARM (Snapdragon, etc.) |

Unzip and keep `NetBridge.exe` and `wintun.dll` together in the same folder.

## Use

1. On the iPhone, open NetBridge and tap **Start Proxy**. Keep the app open.
2. Put the PC on the same network as the phone (the same Wi-Fi, or the phone's Personal Hotspot).
3. Run `NetBridge.exe`. It asks for administrator rights, which it needs to create its network adapter and set routes.
4. Enter the address and port shown on the phone, paste its `socks5://` link, or click **Import QR code image…** and pick a screenshot of the phone's QR code.
5. Click **Connect**.

Closing the window keeps the connection up; NetBridge stays in the notification area (system tray), where you can Disconnect, Show or Quit. If the phone stops answering, the dashboard says so. If the connection drops, NetBridge retries up to 3 times.

**Without a window** (for scripts), run from an administrator prompt:

```
NetBridge.exe --connect socks5://user:pass@192.168.1.20:1080 [--for 300]
```

## Good to know

- **Unsigned build:** Windows shows "Unknown publisher" on the admin prompt, and SmartScreen may warn on first run.
- **DNS:** lookups go through the tunnel. The phone resolves hostnames, so nothing leaks to the local network's DNS.
- **Logs:** `%LOCALAPPDATA%\NetBridge\netbridge.log` ("Open log folder" in the app). Settings are in `%APPDATA%\NetBridge\config.json`; the password is kept in Windows Credential Manager.
- **Cleanup:** disconnecting removes every route and DNS rule NetBridge added. If it's killed, Windows removes the adapter, and NetBridge cleans up the rest on its next launch.

## Credits

`wintun.dll` is the [Wintun](https://www.wintun.net) driver by WireGuard LLC, included unmodified under its license (`wintun-LICENSE.txt` in each zip).
