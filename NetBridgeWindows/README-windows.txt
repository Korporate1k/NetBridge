NetBridge for Windows
=====================

Sends all of this PC's internet traffic (TCP and UDP, IPv4 and IPv6) through
the NetBridge app running on your iPhone.

Requirements
- Windows 10 or 11, 64-bit (x64).
- Keep NetBridge.exe and wintun.dll in the same folder.
- NetBridge asks for administrator rights when it starts. It needs them to
  create its network adapter and to change routes.

Connecting
1. On the iPhone, open NetBridge and tap Start Proxy. Keep the app open.
2. Put the PC on the same network as the phone (the same Wi-Fi or the phone's
   Personal Hotspot).
3. Start NetBridge.exe and enter the address and port shown on the phone, or
   paste its socks5:// link, or click "Import QR code image..." and pick a
   screenshot of the phone's QR code (you can also drag the image onto the
   window).
4. Click Connect.

While connected
- Closing the window keeps the connection up. NetBridge stays in the
  notification area (system tray); right-click its icon to Disconnect, Show or
  Quit.
- "Proxy: Not answering" means the phone app stopped responding. It is
  usually suspended because it went to the background.
- If the connection drops, NetBridge retries up to 3 times (after 2 s, 5 s
  and 15 s).

Without a window (scripts, testing), from an administrator prompt:
    NetBridge.exe --connect socks5://user:pass@192.168.1.20:1080 --for 300
connects for 300 seconds (omit --for to stay connected) and logs its progress.

Logs: %LOCALAPPDATA%\NetBridge\netbridge.log ("Open log folder" in the app).
Settings: %APPDATA%\NetBridge\config.json. The password is stored in
Windows Credential Manager, not in that file.

wintun.dll is the Wintun network driver by WireGuard LLC, included unmodified
under its license (wintun-LICENSE.txt).
