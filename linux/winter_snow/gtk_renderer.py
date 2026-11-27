"""GTK3 overlay, Cairo drawing, timer and control window.

All GUI imports are optional so the module can be imported (and the core can be
tested) on a machine without GTK or a display.  On Wayland the overlay is made a
layer surface when gtk-layer-shell is present; cross-client window geometry and
drag-fling are X11-only and simply are not available there.
"""

import math
import os
import sys
import time

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gtk, Gdk, Gio, GLib
    try:
        from gi.repository import GdkX11
    except Exception:
        GdkX11 = None
    import cairo
except Exception:  # pragma: no cover - depends on the host
    gi = Gtk = Gdk = Gio = GLib = GdkX11 = cairo = None

WAYLAND = (os.environ.get("XDG_SESSION_TYPE") or "").strip().lower() == "wayland"
LAYER_SHELL = None
if WAYLAND and gi is not None:
    try:
        gi.require_version("GtkLayerShell", "0.1")
        from gi.repository import GtkLayerShell
        LAYER_SHELL = GtkLayerShell
    except Exception:  # pragma: no cover - optional dependency
        LAYER_SHELL = None

from winter_snow.controller import Controller
from winter_snow.snow_core import COL_W, FRAME_MS, SnowWorld

ACTIONS = ("pause", "light", "medium", "heavy", "clear", "quit")
ACCELS = {"pause": "p", "light": "1", "medium": "2", "heavy": "3",
          "clear": "c", "quit": "q"}


class GtkRenderer:
    """The platform half of the Renderer protocol."""

    def __init__(self, app=None):
        if Gtk is None or GLib is None or cairo is None:
            raise RuntimeError("MISSING gi: GTK 3 and Cairo are required")
        self.app = app
        self.controller = None  # type: Controller
        self.world = None       # type: SnowWorld
        self._timer_id = 0
        self._last = None
        self._control = None
        self._pause_button = None
        self._warned_no_xlib = False

        self.window = Gtk.Window()
        self.window.set_title("WinterIsComing")
        self.window.set_app_paintable(True)
        self._setup_visual()
        self.window.set_decorations(False)
        self.window.set_keep_above(True)
        self.window.set_accept_focus(False)
        self.window.set_skip_taskbar_hint(True)
        self.window.connect("draw", self._on_draw)
        self.window.connect("delete-event", self._on_delete)

        screen = self.window.get_screen()
        if screen is not None:
            screen.connect("size-changed", self._on_screen_size_changed)
        if WAYLAND and LAYER_SHELL is not None:
            self._setup_layer_shell()  # must precede realise/map
        self.window.realize()
        self._setup_input_transparency()
        self.window.show()

    # -- setup --------------------------------------------------------------

    def _setup_visual(self):
        screen = self.window.get_screen()
        visual = None
        if screen is not None:
            try:
                visual = Gdk.Screen.get_rgba_visual(screen)
            except Exception:
                visual = None
        if visual is None:
            sys.stderr.write("warning: no RGBA visual; transparency may not work\n")
            if screen is not None:
                try:
                    visual = screen.get_system_visual()
                except Exception:
                    visual = None
        if visual is not None:
            self.window.set_visual(visual)

    def _setup_input_transparency(self):
        gdk_window = self.window.get_window()
        if gdk_window is None:
            return
        try:
            gdk_window.set_pass_through(True)
            gdk_window.input_shape_combine_region(cairo.Region(), 0, 0)
        except Exception:
            pass  # older GTK/X servers may not have input shapes
        if (not WAYLAND and GdkX11 is not None
                and hasattr(gdk_window, "set_override_redirect")):
            try:
                gdk_window.set_override_redirect(True)
            except Exception:
                pass

    def _setup_layer_shell(self):
        LAYER_SHELL.init_for_window(self.window)
        LAYER_SHELL.set_layer(self.window, LAYER_SHELL.Layer.OVERLAY)
        LAYER_SHELL.set_anchor(self.window, LAYER_SHELL.Edge.TOP, True)
        LAYER_SHELL.set_anchor(self.window, LAYER_SHELL.Edge.BOTTOM, True)
        LAYER_SHELL.set_anchor(self.window, LAYER_SHELL.Edge.LEFT, True)
        LAYER_SHELL.set_anchor(self.window, LAYER_SHELL.Edge.RIGHT, True)

    @property
    def xid(self):
        """Our own XID, so read_windows can exclude the overlay."""
        gdk_window = self.window.get_window()
        if gdk_window is not None and hasattr(gdk_window, "get_xid"):
            try:
                return int(gdk_window.get_xid())
            except Exception:
                return None
        return None

    # -- Renderer protocol --------------------------------------------------

    def screen_size(self):
        screen = Gdk.Screen.get_default()
        if screen is not None:
            return float(screen.get_width()), float(screen.get_height())
        return 1024.0, 768.0

    def window_rects(self):
        if WAYLAND:
            return []  # no cross-client window geometry on Wayland
        try:
            from winter_snow.x11_windows import read_windows
            return read_windows(exclude_xid=self.xid)
        except RuntimeError:
            self._warn_missing_xlib()
            return []

    def taskbar_top(self):
        if WAYLAND:
            return None
        try:
            from winter_snow.x11_windows import read_taskbar_top
            return read_taskbar_top()
        except RuntimeError:
            self._warn_missing_xlib()
            return None

    def _warn_missing_xlib(self):
        if not self._warned_no_xlib:
            sys.stderr.write("warning: python-xlib unavailable; window piles disabled\n")
            self._warned_no_xlib = True

    def present_frame(self, world):
        self.world = world
        self.window.queue_draw()

    def set_overlay_visible(self, visible):
        if visible:
            self.window.show()
        else:
            self.window.hide()
        if self._pause_button is not None:
            self._pause_button.set_label("Resume snow" if not visible else "Pause snow")

    def set_overlay_geometry(self, x, y, w, h):
        self.window.move(int(x), int(y))
        self.window.resize(int(w), int(h))

    # -- control window / commands -----------------------------------------

    def _command(self, name):
        if self.controller is not None:
            self.controller.handle_command(name)

    def show_control_window(self):
        if self._control is not None:
            self._control.present()
            return
        window = Gtk.Window(title="WinterIsComing ❄")
        window.set_default_size(220, 280)
        window.set_keep_above(True)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_border_width(12)

        paused = self.controller is not None and self.controller.world.paused
        self._pause_button = Gtk.Button(label="Resume snow" if paused else "Pause snow")
        self._pause_button.connect("clicked", lambda *_: self._command("pause"))
        box.pack_start(self._pause_button, False, False, 0)
        for label, name in (("Light", "light"), ("Medium", "medium"),
                            ("Heavy", "heavy"), ("Clear snow", "clear"),
                            ("Quit", "quit")):
            button = Gtk.Button(label=label)
            button.connect("clicked", lambda *_command_args, n=name: self._command(n))
            box.pack_start(button, False, False, 0)
        window.add(box)
        window.connect("delete-event", self._on_control_delete)
        window.show_all()
        self._control = window

    def _on_control_delete(self, widget, event):
        self._command("quit")
        return True

    def _on_delete(self, widget, event):
        self._command("quit")
        return True

    # -- timer / drawing ----------------------------------------------------

    def start(self):
        if self._timer_id:
            return
        self._last = time.monotonic()
        self._timer_id = GLib.timeout_add(FRAME_MS, self._on_tick)

    def _stop_timer(self):
        if self._timer_id:
            GLib.source_remove(self._timer_id)
            self._timer_id = 0

    def _on_tick(self):
        now = time.monotonic()
        dt = 0.0 if self._last is None else min(now - self._last, 1.0 / 20.0)
        self._last = now
        if self.controller is not None:
            self.controller.tick(dt)
        return True

    def _on_screen_size_changed(self, screen):
        width, height = self.screen_size()
        self.set_overlay_geometry(0.0, 0.0, width, height)
        if self.controller is not None:
            self.controller.world.resize(width, height)

    def _on_draw(self, widget, cr):
        cr.set_operator(cairo.OPERATOR_CLEAR)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        world = self.world
        if world is None:
            return False
        for flake in world.flakes:
            if not flake.clump and flake.layer < 2:
                self._draw_flake(cr, flake)
        for pile in world.piles.values():
            self._draw_pile(cr, pile)
        self._draw_pile(cr, world.ground)
        for flake in world.flakes:
            if flake.clump or flake.layer == 2:
                self._draw_flake(cr, flake)
        return False

    @staticmethod
    def _draw_flake(cr, flake):
        cr.set_source_rgba(1.0, 1.0, 1.0, min(1.0, max(0.0, flake.alpha)))
        cr.arc(flake.x, flake.y, flake.size * 1.1, 0.0, 2.0 * math.pi)
        cr.fill()

    @staticmethod
    def _draw_pile(cr, pile):
        cr.set_source_rgba(0.70, 0.78, 0.92, 0.9)
        cr.rectangle(pile.min_x, pile.top_y, pile.width, 1.5)
        cr.fill()
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.97)
        for c in range(pile.count):
            if pile.occ[c] or pile.h[c] < 0.3:
                continue
            cr.rectangle(pile.min_x + c * COL_W, pile.surface(c), COL_W, pile.h[c])
        cr.fill()

    def quit(self):
        self._stop_timer()
        for window in (self._control, self.window):
            if window is not None:
                try:
                    window.destroy()
                except Exception:
                    pass
        self._control = None
        if self.app is not None:
            self.app.quit()


def run_app(args):
    """Build the GTK application, actions and accelerators, then run it."""
    if Gtk is None or Gio is None or GLib is None:
        print("MISSING gi", file=sys.stderr)
        return 2
    app = Gtk.Application()
    renderer = [None]

    def activate(application):
        instance = GtkRenderer(app=application)
        renderer[0] = instance
        world = SnowWorld(*instance.screen_size())
        world.set_amount(args.snow)
        controller = Controller(world, instance)
        instance.controller = controller
        if args.clear:
            controller.handle_command("clear")
        if args.pause:
            controller.handle_command("pause")
        for name in ACTIONS:
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda _action, _param, n=name: instance._command(n))
            application.add_action(action)
        instance.start()
        instance.show_control_window()

    app.connect("activate", activate)
    for name, accel in ACCELS.items():
        app.set_accels_for_action("app." + name, [accel])
    return int(app.run([]))
