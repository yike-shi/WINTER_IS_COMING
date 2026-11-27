# ❄︎ WinterIsComing ❄︎

A little snowfall for your desktop, on Mac and Windows ☃️

Snow drifts down and settles on your windows, the Dock and the taskbar. Roll it into snowballs, stack them into a snowman, and hang some fairy lights while you're at it.

<!-- ![demo](docs/demo.gif) -->

## 🎁 Download

| | |
|---|---|
| **Mac** | [WinterIsComing-mac-v1.0.zip](https://github.com/yike-shi/WINTER_IS_COMING/releases/latest) · unzip, move it to Applications, open it |
| **Windows** (beta) | [WinterIsComing-windows-v0.1-beta.zip](https://github.com/yike-shi/WINTER_IS_COMING/releases/tag/windows-v0.1) · unzip, open `WinterIsComing.exe` |

On the release page, grab the zip with the app's name (not the "Source code" ones).

**The first time you open it**, your computer may stop it, because the app isn't signed with a paid developer account yet:

- **Mac**: click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Just once, and you're all set.
- **Windows**: click **More info → Run anyway**.

Don't worry, the app never connects to the internet, and all of its code is right here 💙

## ✨ What you can do

- **Watch it snow**: flakes drift down in three soft layers and pile up on your windows
- **Drag a window**: the snow on top slides right off
- **Roll a snowball**: move your mouse sideways over the snow, no clicking needed
- **Push it**: roll one snowball into another and give it a nudge
- **Carry it**: hold the left mouse button on a snowball and take it anywhere
- **Build a snowman**: stack three snowballs, and he gets a carrot nose and a red scarf ⛄
- **Hang fairy lights**: turn them on from the menu and watch them swing into place

Everything else lives in the ❄︎ menu: in the menu bar on Mac, in the system tray on Windows (click **^** if you don't see it). Pause, change how much snow falls, clear it, or peek at how to play again.

On Mac, for snow on the Dock too, allow **WinterIsComing** in System Settings → Privacy & Security → Accessibility.

## 🛠️ Build it yourself

**Mac** (needs `swiftc`; run `xcode-select --install` if you don't have it)

```sh
git clone https://github.com/yike-shi/WINTER_IS_COMING.git
cd WINTER_IS_COMING
zsh build.sh            # run it
zsh make_app.sh 1.0     # or package it as an .app
```

**Windows** (needs the [.NET 8 SDK](https://dotnet.microsoft.com/download))

```sh
cd WINTER_IS_COMING/windows
dotnet run -c Release
```

## Linux version 🐧 (beta)

Linux (beta, X11 preferred). Snow falls across your desktop, piles up on top of windows and along the bottom of the screen (or on your taskbar/dock), and dragging a window still sends the snow flying — the faster you drag, the farther it goes. That full effect needs X11: window-top piles and drag-fling are X11-only and are **not** available on Wayland, where the overlay can't see other windows.

There's no system tray here. A small on-screen control window lets you pause or resume the snow, pick light, medium or heavy, clear the snow, and quit. The same actions have keyboard shortcuts: `p` to pause, `1`/`2`/`3` for the snow amount, `c` to clear and `q` to quit. Snowballs, snowmen and fairy lights aren't included, and this build doesn't aim to match the macOS or Windows versions feature for feature.

Install the Python bindings for GTK 3 and Cairo, plus python-xlib for the window effects:

Ubuntu/Debian:

```sh
sudo apt install python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 python3-xlib
```

Fedora:

```sh
sudo dnf install python3 python3-gobject python3-cairo gtk3 python3-xlib
```

Arch:

```sh
sudo pacman -S python gtk3 python-gobject python-cairo python-xlib
```

Then run it, or check your setup first:

```sh
python3 linux/winter_snow/main.py --snow medium
python3 linux/winter_snow/main.py --diagnose
```

`--diagnose` just prints what it finds — it never opens a window, so it's handy when something looks off. On Wayland, installing `gtk-layer-shell` gives you a full-screen overlay layer.

## 🎨 Make it yours

Every setting lives at the top of `WinterIsComing.swift` and `windows/Program.cs`: how much snow falls, how fast, how big a snowball can grow. Change a number and run it again.

## 💙 License

[MIT](LICENSE) · Made with 💙 and a little help from Claude
