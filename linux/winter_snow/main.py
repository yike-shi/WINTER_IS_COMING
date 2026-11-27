"""Command line entry point for the Linux version of WinterIsComing ❄.

Run: python3 linux/winter_snow/main.py --snow medium
     python3 linux/winter_snow/main.py --diagnose
"""

import argparse
import importlib
import os
import sys

# Allow both `python3 linux/winter_snow/main.py` and `import winter_snow.main`.
_HERE = os.path.dirname(os.path.abspath(__file__))
_LINUX_ROOT = os.path.dirname(_HERE)
if _LINUX_ROOT not in sys.path:
    sys.path.insert(0, _LINUX_ROOT)

from winter_snow.snow_core import AMOUNTS  # noqa: E402


def build_parser():
    parser = argparse.ArgumentParser(
        prog="winter_snow", description="Snow on your Linux desktop."
    )
    parser.add_argument("--snow", choices=sorted(AMOUNTS), default="medium",
                        help="how much snow falls (default: medium)")
    parser.add_argument("--pause", action="store_true",
                        help="start with the snowfall paused")
    parser.add_argument("--clear", action="store_true",
                        help="start with empty snow piles")
    parser.add_argument("--diagnose", action="store_true",
                        help="print environment diagnostics and exit (no window)")
    return parser


def _load(name):
    return importlib.import_module(name)


def diagnose(env=None, load=None):
    """Return (output lines, exit code). Never opens a window, never raises."""
    env = dict(os.environ) if env is None else dict(env)
    if load is None:
        load = _load
    lines = []

    session = (env.get("XDG_SESSION_TYPE") or "").strip().lower()
    if session == "wayland":
        pass
    elif session == "x11" or (not session and bool(env.get("DISPLAY"))):
        session = "x11"
    else:
        lines.append("UNKNOWN SESSION " + session if env.get("DISPLAY") else "NO DISPLAY")
        return lines, 3

    missing = []
    gi = None
    Gtk = Gdk = None
    try:
        gi = load("gi")
        gi.require_version("Gtk", "3.0")
        Gtk = load("gi.repository.Gtk")
        Gdk = load("gi.repository.Gdk")
    except Exception:
        missing.append("gi")

    Xlib = None
    if session == "x11":
        try:
            Xlib = load("Xlib")
            getattr(Xlib, "display")
            getattr(Xlib, "Xatom")
        except Exception:
            missing.append("Xlib")

    if missing:
        for name in missing:
            lines.append("MISSING " + name)
        return lines, 2

    lines.append("SESSION " + session)
    try:
        lines.append("GTK {}.{}.{}".format(
            int(Gtk.get_major_version()), int(Gtk.get_minor_version()),
            int(Gtk.get_micro_version())
        ))
    except Exception:
        lines.append("GTK unknown")
    try:
        screen = Gdk.Screen.get_default()
        rgba = screen.get_rgba_visual() if screen is not None else None
        composited = screen.is_composited() if screen is not None else False
        lines.append("RGBA " + ("yes" if rgba is not None else "no"))
        lines.append("COMPOSITED " + ("yes" if composited else "no"))
    except Exception:
        lines.append("RGBA no")
        lines.append("COMPOSITED no")

    if session == "x11":
        available = False
        try:
            display_obj = Xlib.display.Display(env.get("DISPLAY"))
            root = display_obj.screen().root
            atom = display_obj.intern_atom("_NET_CLIENT_LIST")
            available = root.get_full_property(atom, Xlib.Xatom.WINDOW) is not None
        except Exception:
            available = False
        lines.append("CLIENT_LIST " + ("yes" if available else "no"))
    else:
        available = False
        try:
            gi.require_version("GtkLayerShell", "0.1")
            load("gi.repository.GtkLayerShell")
            available = True
        except Exception:
            available = False
        lines.append("LAYER_SHELL " + ("yes" if available else "no"))
        if not available:
            return lines, 4
    return lines, 0


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.diagnose:
        lines, code = diagnose()
        for line in lines:
            print(line)
        return code
    from winter_snow.gtk_renderer import run_app
    return run_app(args)


if __name__ == "__main__":
    sys.exit(main())
