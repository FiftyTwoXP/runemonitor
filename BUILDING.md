# RuneMonitor source and how to check the downloads

This is the complete source for RuneMonitor 1.0.0:

| Folder | What it is |
|---|---|
| `plugins/runemonitor` | The in-game plugin (Lua). The same files as the Plugin Hub upload, `runemonitor-1.0.0.zip`. |
| `relay` | RuneMonitor Relay, the program on your PC (Node.js), including the phone dashboard in `relay/public`. |
| `android` | The Android app (Kotlin). |
| `tools` | Scripts that produced the dashboard's interface images from game data. Not needed to build. |

## What each part does

- **The plugin** reads your character's status in game and sends it only to
  `http://127.0.0.1:8787`, the relay on the same PC (see `plugin.json`). It
  never sends key presses or clicks. Network requests are in `main.lua`
  (`request`) and `controller.lua`.
- **The relay** (`relay/server.mjs`) accepts the plugin only from the same PC
  and serves the dashboard to phones you pair with a QR code. Its only other
  internet requests are item prices and pictures from RuneScape's official
  item database (`relay/lib/prices.mjs`, `relay/lib/item-icons.mjs`) and map
  pictures from RuneApps (`relay/lib/runeapps-tiles.mjs`). The packaged exe
  adds `relay/app/launcher.mjs` (the window text, the data folder and the
  optional Start with Windows file in `relay/app/startup.mjs`).
- **The app** shows the dashboard and turns the relay's alerts into phone
  notifications (`android/app/src/main/java/com/runemonitor/app`).

## Rebuild the relay exe and compare it

The exe is reproducible: built from this source with the same Node.js, it is
byte-for-byte identical to the release download.

1. On Windows, install **Node.js 24.21.0** (64-bit) from nodejs.org. The exe
   is Node itself plus RuneMonitor's code, so the Node version must match.
2. In a terminal:

   ```
   cd relay
   npm ci
   npm test
   npm run build:exe
   ```

   `npm ci` installs the exact library versions in `package-lock.json`.
3. Compare the result with the release's checksum:

   ```
   certutil -hashfile dist\RuneMonitor-Relay.exe SHA256
   ```

   It should match the `RuneMonitor-Relay.exe` line in the release notes.

`relay/scripts/build-exe.mjs` shows every step: it bundles the code with
esbuild, packs the dashboard files in, copies `node.exe`, sets the program's
name and icon, and writes `THIRD-PARTY-NOTICES.txt`.

## The Android app

Build it from `android` with Android Studio, or run
`gradlew testDebugUnitTest assembleDebug` with Java 17+. Your build is
signed with your own debug key, so it will not match the release APK byte for
byte. The release APK is signed with RuneMonitor's key, whose SHA-256
certificate fingerprint is:

```
65:31:77:A4:1B:1B:99:77:FC:11:36:C4:8C:DD:21:83:A6:A1:FD:B3:58:BF:FE:1B:0F:7A:35:38:3D:2B:0C:5D
```

Check a download with `apksigner verify --print-certs RuneMonitor-1.0.1.apk`
(Android SDK build-tools).

## The plugin

`plugins/runemonitor` is exactly what was uploaded to the Plugin Hub. To run it
yourself on the developer beta world, point the developer console at the
`plugins` folder (`plugins_setpath <full path>`), then `prf` and
`pon runemonitor`. The plugin's README lists the permission commands.
