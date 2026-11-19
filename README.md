# LidKeeper

Keep your Mac running with the lid closed — screen off, system on.

The opposite of [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704): the system keeps running while the display is allowed to turn off.

## How it works

LidKeeper attaches a private `CGVirtualDisplay` and mirrors it to the built-in
display. macOS treats that as an external monitor and enters native clamshell
mode, so closing the lid turns the screen off instead of forcing a sleep.

Alongside the display it holds an `IOPMAssertionTypeNoIdleSleep` assertion so
macOS does not power down the WiFi/network hardware when the lid magnet sensor
trips. If the assertion cannot be acquired, the menu bar reports
`⚠️ Display active, sleep assertion failed` and retries periodically while the
display is on.

Each enable gets a fresh virtual display serial, because macOS refuses a new
display that reuses the identity of a recently destroyed one. Disabling clears
the display's modes and releases the reference `init` hands back, so the entry
disappears from System Settings → Displays instead of accumulating.

## How this differs from `caffeinate`

`caffeinate -i -m -s` asserts three things separately. LidKeeper asserts only
idle system sleep, and lets clamshell mode cover the rest — that is what keeps
the screen off while the machine stays up.

- Nothing polls `pmset displaysleepnow`; the screen goes off because clamshell
  mode blanks it, not because a timer forces it.
- Disk sleep (`-m`) and system sleep (`-s`) are not asserted individually.

Both are deliberate rather than missing: in testing, a closed lid held a live
WiFi link for several minutes while `pmset` reported sleep continuously
prevented for the whole run.

## Requirements

- Apple Silicon Mac (M1–M4)
- macOS 14 Sonoma or later

## Build & Install

```bash
chmod +x build.sh
./build.sh
```

This compiles the Swift source, creates `LidKeeper.app` in `/Applications`, and ad-hoc signs it.

## Launch at Boot (optional)

The bundled `com.lidkeeper.plist` restarts LidKeeper if it crashes, but stays
down after a deliberate Quit. It throttles restarts by 10s so a crash on start
cannot hot-loop. Anything in `~/Library/LaunchAgents` is loaded again at login,
so this also covers boot.

```bash
mkdir -p ~/Library/LaunchAgents
cp com.lidkeeper.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.lidkeeper.plist
```

To stop managing it that way again:

```bash
launchctl unload ~/Library/LaunchAgents/com.lidkeeper.plist
rm ~/Library/LaunchAgents/com.lidkeeper.plist
```

Or skip launchd entirely and add `/Applications/LidKeeper.app` to Login Items in
System Settings → General → Login Items.

## Usage

- **Green `LK`** in the menu bar = active. Close the lid and the display will turn off while the system keeps running.
- **Grey `LK`** = disabled. Normal macOS sleep behavior.
- Click the icon to toggle on/off or quit.

LidKeeper never calls `pmset`; all of the above runs through CoreGraphics and
Power Management APIs, so your `pmset` display-sleep setting is left alone.

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
