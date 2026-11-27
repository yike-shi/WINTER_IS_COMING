"""Tests for the CLI, diagnose mode and the guarded X11/GTK platform layer."""

import importlib.util
import io
import sys
from types import SimpleNamespace

import pytest

from winter_snow import main as cli
from winter_snow import x11_windows as xw


# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

def test_parser_defaults_and_snow_choices():
    parser = cli.build_parser()
    args = parser.parse_args([])
    assert args.snow == "medium"
    assert args.pause is False
    assert args.clear is False
    assert args.diagnose is False

    args = parser.parse_args(["--snow", "heavy", "--pause", "--clear", "--diagnose"])
    assert args.snow == "heavy"
    assert args.pause is True
    assert args.clear is True
    assert args.diagnose is True

    with pytest.raises(SystemExit):
        parser.parse_args(["--snow", "blizzard"])


def test_help_lists_all_flags():
    parser = cli.build_parser()
    out = io.StringIO()
    parser.print_help(file=out)
    text = out.getvalue()
    for flag in ("--snow", "--pause", "--clear", "--diagnose", "--help"):
        assert flag in text


def test_main_dispatches_diagnose_without_opening_windows(monkeypatch, capsys):
    monkeypatch.setattr(cli, "diagnose", lambda: (["SESSION x11", "GTK 3.24.33"], 0))
    code = cli.main(["--diagnose"])
    assert code == 0
    assert capsys.readouterr().out == "SESSION x11\nGTK 3.24.33\n"


# --------------------------------------------------------------------------
# Diagnose with injected environment / import stubs
# --------------------------------------------------------------------------

class StubGi:
    def __init__(self, layer_shell=True):
        self.requested = []
        self.layer_shell = layer_shell

    def require_version(self, namespace, version):
        self.requested.append((namespace, version))
        if namespace == "GtkLayerShell" and not self.layer_shell:
            raise ImportError("no gtk-layer-shell")


class StubGtk:
    @staticmethod
    def get_major_version():
        return 3

    @staticmethod
    def get_minor_version():
        return 24

    @staticmethod
    def get_micro_version():
        return 33


class StubScreen:
    default = None

    def __init__(self, rgba=True, composited=False):
        self.rgba = rgba
        self.composited = composited
        StubScreen.default = self

    def get_rgba_visual(self):
        return object() if self.rgba else None

    def is_composited(self):
        return self.composited

    @classmethod
    def get_default(cls):
        return cls.default


class StubGdk:
    Screen = StubScreen


class StubDisplay:
    def __init__(self, has_client_list=True):
        self.has_client_list = has_client_list

    def intern_atom(self, name):
        return name

    def screen(self):
        outer = self

        class Root:
            def get_full_property(self, atom, kind):
                if atom == "_NET_CLIENT_LIST" and outer.has_client_list:
                    return SimpleNamespace(value=[1, 2])
                return None
        return SimpleNamespace(root=Root())


class StubXlib:
    display = SimpleNamespace(Display=lambda name=None: StubDisplay())

    class Xatom:
        WINDOW = 33


def make_loader(gi=None, gtk=None, gdk=None, xlib=None, layer_shell=None):
    modules = {}
    if gi is not None:
        modules["gi"] = gi
    if gtk is not None:
        modules["gi.repository.Gtk"] = gtk
    if gdk is not None:
        modules["gi.repository.Gdk"] = gdk
    if layer_shell is not None:
        modules["gi.repository.GtkLayerShell"] = layer_shell
    if xlib is not None:
        modules["Xlib"] = xlib

    def load(name):
        if name in modules:
            return modules[name]
        raise ImportError("stub has no module " + name)
    return load


def test_diagnose_reports_no_display_without_a_session():
    lines, code = cli.diagnose(env={}, load=make_loader())
    assert lines == ["NO DISPLAY"]
    assert code == 3


def test_diagnose_reports_missing_gi():
    lines, code = cli.diagnose(
        env={"DISPLAY": ":0", "XDG_SESSION_TYPE": "x11"}, load=make_loader()
    )
    assert lines == ["MISSING gi", "MISSING Xlib"]
    assert code == 2


def test_diagnose_reports_missing_xlib_on_x11():
    gi = StubGi()
    lines, code = cli.diagnose(
        env={"DISPLAY": ":0", "XDG_SESSION_TYPE": "x11"},
        load=make_loader(gi=gi, gtk=StubGtk, gdk=StubGdk),
    )
    assert lines == ["MISSING Xlib"]
    assert code == 2


def test_diagnose_x11_success_lines():
    StubScreen(rgba=True, composited=False)
    gi = StubGi()
    lines, code = cli.diagnose(
        env={"DISPLAY": ":0", "XDG_SESSION_TYPE": "x11"},
        load=make_loader(gi=gi, gtk=StubGtk, gdk=StubGdk, xlib=StubXlib),
    )
    assert code == 0
    assert lines == ["SESSION x11", "GTK 3.24.33", "RGBA yes",
                     "COMPOSITED no", "CLIENT_LIST yes"]
    assert ("Gtk", "3.0") in gi.requested


def test_diagnose_x11_without_client_list_reports_no():
    StubScreen(rgba=False, composited=True)
    no_list = StubDisplay(has_client_list=False)

    class XlibNoList:
        display = SimpleNamespace(Display=lambda name=None: no_list)
        Xatom = StubXlib.Xatom

    lines, code = cli.diagnose(
        env={"DISPLAY": ":0", "XDG_SESSION_TYPE": "x11"},
        load=make_loader(gi=StubGi(), gtk=StubGtk, gdk=StubGdk, xlib=XlibNoList),
    )
    assert code == 0
    assert lines == ["SESSION x11", "GTK 3.24.33", "RGBA no",
                     "COMPOSITED yes", "CLIENT_LIST no"]


def test_diagnose_wayland_success_uses_layer_shell():
    StubScreen(rgba=True, composited=True)
    gi = StubGi()
    lines, code = cli.diagnose(
        env={"XDG_SESSION_TYPE": "wayland"},
        load=make_loader(gi=gi, gtk=StubGtk, gdk=StubGdk, layer_shell=object()),
    )
    assert code == 0
    assert lines == ["SESSION wayland", "GTK 3.24.33", "RGBA yes",
                     "COMPOSITED yes", "LAYER_SHELL yes"]
    assert ("GtkLayerShell", "0.1") in gi.requested
    assert not any("CLIENT_LIST" in line for line in lines)


def test_diagnose_wayland_without_layer_shell_exits_four():
    StubScreen()
    lines, code = cli.diagnose(
        env={"XDG_SESSION_TYPE": "wayland"},
        load=make_loader(gi=StubGi(layer_shell=False), gtk=StubGtk, gdk=StubGdk),
    )
    assert code == 4
    assert lines[-1] == "LAYER_SHELL no"


def test_diagnose_never_raises_on_broken_imports():
    def evil_load(name):
        raise RuntimeError("boom " + name)

    lines, code = cli.diagnose(env={"DISPLAY": ":0", "XDG_SESSION_TYPE": "x11"},
                              load=evil_load)
    assert lines == ["MISSING gi", "MISSING Xlib"]
    assert code == 2


# --------------------------------------------------------------------------
# Optional GUI modules import cleanly without a display
# --------------------------------------------------------------------------

def test_gtk_and_x11_modules_import_without_a_display():
    import winter_snow.gtk_renderer as gr
    assert hasattr(gr, "GtkRenderer")
    assert hasattr(gr, "run_app")
    assert hasattr(xw, "read_windows")
    assert hasattr(xw, "read_taskbar_top")


# --------------------------------------------------------------------------
# X11 window reading with a fake display
# --------------------------------------------------------------------------

class FakeWindow:
    def __init__(self, wid, x, y, w, h, map_state=2, types=None):
        self.wid = wid
        self.x, self.y, self.w, self.h = x, y, w, h
        self.map_state = map_state
        self.types = types or []

    def get_attributes(self):
        return SimpleNamespace(map_state=self.map_state)

    def get_geometry(self):
        return SimpleNamespace(x=0, y=0, width=self.w, height=self.h)

    def translate_coords(self, root, x, y):
        return SimpleNamespace(x=self.x, y=self.y, same_screen=True)

    def get_full_property(self, atom, kind):
        if atom == "_NET_WM_WINDOW_TYPE" and self.types:
            return SimpleNamespace(value=self.types)
        return None


class FakeDisplay:
    def __init__(self, windows, client_ids=None, screen_h=800, tree_ids=None,
                 stacking_ids=None):
        self.windows = {window.wid: window for window in windows}
        self.screen_h = screen_h
        children = client_ids if tree_ids is None else tree_ids
        root = SimpleNamespace(
            client_ids=client_ids,
            stacking_ids=stacking_ids,
            get_full_property=self._root_property,
            query_tree=lambda: SimpleNamespace(
                children=[SimpleNamespace(id=wid) for wid in (children or [])]
            ),
        )
        self._screen = SimpleNamespace(root=root, height_in_pixels=screen_h)

    def _root_property(self, atom, kind):
        root = self._screen.root
        if atom == "_NET_CLIENT_LIST_STACKING" and root.stacking_ids is not None:
            return SimpleNamespace(value=list(root.stacking_ids))
        if atom == "_NET_CLIENT_LIST" and root.client_ids is not None:
            return SimpleNamespace(value=list(root.client_ids))
        return None

    def intern_atom(self, name, only_if_exists=False):
        return name

    def screen(self):
        return self._screen

    def create_resource_object(self, kind, wid):
        return self.windows.get(wid)


def test_x11_module_imports_with_real_xlib_layout_and_viewable_state(monkeypatch):
    # python-xlib defines IsViewable in Xlib.X (value 2), not in Xlib.Xutil.
    # A real X11 host must import the module and treat map_state == 2 as viewable.
    fake_xlib = SimpleNamespace(
        X=SimpleNamespace(IsViewable=2, AnyPropertyType=0),
        Xutil=SimpleNamespace(),  # deliberately has no IsViewable
        display=SimpleNamespace(Display=lambda name=None: None),
    )
    monkeypatch.setitem(sys.modules, "Xlib", fake_xlib)
    spec = importlib.util.spec_from_file_location(
        "winter_snow._x11_windows_xlib_probe", xw.__file__
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert module.IS_VIEWABLE == 2
    viewable = FakeWindow(41, 10, 10, 120, 80, map_state=2)
    hidden = FakeWindow(42, 10, 10, 120, 80, map_state=1)
    display = FakeDisplay([viewable, hidden], client_ids=[41, 42])
    assert [window.id for window in module.read_windows(display_obj=display)] == [41]


def test_read_windows_falls_back_to_client_list_and_filters():
    windows = [
        FakeWindow(10, 100, 50, 200, 100),
        FakeWindow(11, 100, 50, 60, 100),               # too narrow
        FakeWindow(12, 100, 50, 200, 100, map_state=0),  # not viewable
        FakeWindow(13, 300, 50, 200, 100),               # our own overlay
    ]
    display = FakeDisplay(windows, client_ids=[10, 11, 12, 13])
    got = xw.read_windows(exclude_xid=13, display_obj=display)
    assert [window.id for window in got] == [10]
    assert (got[0].l, got[0].t, got[0].r, got[0].b) == (100, 50, 300, 150)


def test_read_windows_uses_stacking_order_front_first():
    # EWMH: _NET_CLIENT_LIST is oldest-first mapping order, while
    # _NET_CLIENT_LIST_STACKING is bottom-to-top.  The latest-mapped window is
    # on top, so the front-most overlapping window must come first.
    behind = FakeWindow(31, 100, 50, 200, 100)
    front = FakeWindow(32, 120, 60, 200, 100)
    display = FakeDisplay([behind, front], client_ids=[31, 32],
                          stacking_ids=[31, 32])
    got = xw.read_windows(display_obj=display)
    assert [window.id for window in got] == [32, 31]


def test_read_windows_falls_back_to_query_tree():
    windows = [FakeWindow(21, 10, 10, 120, 80)]
    display = FakeDisplay(windows, client_ids=None, tree_ids=[21])
    got = xw.read_windows(display_obj=display)
    assert [window.id for window in got] == [21]


def test_read_taskbar_top_finds_bottom_dock_only():
    dock = FakeWindow(20, 0, 770, 1024, 30,
                      types=["_NET_WM_WINDOW_TYPE_DOCK"])
    top_dock = FakeWindow(21, 0, 0, 1024, 30,
                          types=["_NET_WM_WINDOW_TYPE_DOCK"])
    plain = FakeWindow(22, 0, 770, 1024, 30)
    display = FakeDisplay([dock, top_dock, plain], client_ids=[20, 21, 22],
                          screen_h=800)
    assert xw.read_taskbar_top(display_obj=display) == pytest.approx(770.0)

    plain_only = FakeDisplay([plain], client_ids=[22], screen_h=800)
    assert xw.read_taskbar_top(display_obj=plain_only) is None
