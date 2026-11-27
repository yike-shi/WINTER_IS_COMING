"""Read other X11 clients' geometry via EWMH, with a query_tree fallback.

Every Xlib import is optional: importing this module on Wayland or macOS must
not fail, and it is never imported by the simulation core.
"""

import os

from winter_snow.snow_core import Win

try:
    from Xlib import X, Xutil, display
except Exception:  # pragma: no cover - depends on the host
    X = Xutil = display = None

# python-xlib defines IsViewable (= 2) in Xlib.X, not in Xlib.Xutil.
IS_VIEWABLE = getattr(X, "IsViewable", 2) if X is not None else 2
ANY_PROPERTY_TYPE = X.AnyPropertyType if X is not None else 0

MIN_WIDTH = 80
MIN_HEIGHT = 40


def _display(display_obj=None, env=None):
    if display_obj is not None:
        return display_obj
    if display is None:
        raise RuntimeError("MISSING Xlib (python-xlib is required on X11)")
    env = os.environ if env is None else env
    name = env.get("DISPLAY")
    if not name:
        raise RuntimeError("NO DISPLAY")
    return display.Display(name)


def _client_ids(display_obj, root):
    """Return client ids front-to-back for the snow simulation.

    EWMH defines _NET_CLIENT_LIST_STACKING as bottom-to-top stacking order and
    _NET_CLIENT_LIST as initial mapping order (oldest first).  The simulation
    walks windows front-to-back, so the stacking property must be reversed;
    the mapping-order property is only the least-bad fallback.  QueryTree also
    returns children bottom-to-top, so that fallback is reversed as well.
    See https://specifications.freedesktop.org/wm-spec/wm-spec-1.4.html
    """
    try:
        prop = root.get_full_property(
            display_obj.intern_atom("_NET_CLIENT_LIST_STACKING"), ANY_PROPERTY_TYPE
        )
        if prop is not None and prop.value:
            return [int(wid) for wid in reversed(prop.value)]
    except Exception:
        pass
    try:
        prop = root.get_full_property(
            display_obj.intern_atom("_NET_CLIENT_LIST"), ANY_PROPERTY_TYPE
        )
        if prop is not None and prop.value:
            return [int(wid) for wid in prop.value]
    except Exception:
        pass
    try:
        children = root.query_tree().children
        return [int(child.id) for child in reversed(list(children))]
    except Exception:
        return []


def read_windows(exclude_xid=None, display_obj=None, env=None):
    """Return viewable, reasonably sized top-level windows as ``Win`` objects."""
    d = _display(display_obj, env)
    root = d.screen().root
    windows = []
    for wid in _client_ids(d, root):
        if exclude_xid is not None and wid == int(exclude_xid):
            continue
        try:
            w = d.create_resource_object("window", wid)
            if w.get_attributes().map_state != IS_VIEWABLE:
                continue
            geometry = w.get_geometry()
            if geometry.width < MIN_WIDTH or geometry.height < MIN_HEIGHT:
                continue
            pos = w.translate_coords(root, 0, 0)
            left, top = float(pos.x), float(pos.y)
            windows.append(Win(wid, left, top,
                               left + geometry.width, top + geometry.height))
        except Exception:
            continue
    return windows


def read_taskbar_top(display_obj=None, env=None, screen_h=None):
    """Top edge of a visible bottom dock/taskbar, or ``None``."""
    d = _display(display_obj, env)
    screen = d.screen()
    root = screen.root
    if screen_h is None:
        screen_h = getattr(screen, "height_in_pixels", 0) or 0
    dock_atom = d.intern_atom("_NET_WM_WINDOW_TYPE_DOCK")
    type_atom = d.intern_atom("_NET_WM_WINDOW_TYPE")
    for wid in _client_ids(d, root):
        try:
            w = d.create_resource_object("window", wid)
            prop = w.get_full_property(type_atom, ANY_PROPERTY_TYPE)
            if prop is None or dock_atom not in prop.value:
                continue
            if w.get_attributes().map_state != IS_VIEWABLE:
                continue
            geometry = w.get_geometry()
            pos = w.translate_coords(root, 0, 0)
            top = float(pos.y)
            bottom = top + geometry.height
            if top >= screen_h / 2.0 and bottom >= screen_h - 4:
                return top
        except Exception:
            continue
    return None
