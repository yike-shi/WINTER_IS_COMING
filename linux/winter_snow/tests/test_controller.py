"""Tests for the renderer contract and the GUI-independent controller."""

import inspect
import random

import pytest

from winter_snow import snow_core as core
from winter_snow.controller import COMMANDS, Controller, FakeRenderer, Renderer


# --------------------------------------------------------------------------
# Renderer contract / in-memory fake
# --------------------------------------------------------------------------

def test_command_strings_are_exact():
    assert COMMANDS == ("pause", "light", "medium", "heavy", "clear", "quit")


def test_fake_renderer_satisfies_the_renderer_protocol():
    renderer = FakeRenderer()
    assert isinstance(renderer, Renderer)
    for name in ("screen_size", "window_rects", "taskbar_top", "present_frame",
                 "set_overlay_visible", "set_overlay_geometry",
                 "show_control_window", "quit"):
        assert callable(getattr(renderer, name))


def test_fake_renderer_returns_scripted_state_and_records_calls():
    windows = [core.Win(1, 10.0, 20.0, 110.0, 90.0)]
    renderer = FakeRenderer(size=(800.0, 600.0), windows=windows, taskbar_top=580.0)
    assert renderer.screen_size() == (800.0, 600.0)
    assert renderer.window_rects() == windows
    assert renderer.taskbar_top() == pytest.approx(580.0)

    world = core.SnowWorld(800.0, 600.0, rng=random.Random(1))
    renderer.present_frame(world)
    renderer.set_overlay_visible(False)
    renderer.set_overlay_geometry(0.0, 0.0, 800.0, 600.0)
    renderer.show_control_window()
    renderer.quit()

    assert renderer.presented_frames == [world]
    assert renderer.overlay_visibility == [False]
    assert renderer.overlay_geometry == [(0.0, 0.0, 800.0, 600.0)]
    assert renderer.control_calls == 1
    assert renderer.quit_calls == 1


def test_controller_has_no_gui_imports():
    source = inspect.getsource(__import__("winter_snow.controller", fromlist=["x"]))
    for banned in ("import gi", "from gi", "import Gtk", "import cairo", "Xlib"):
        assert banned not in source


# --------------------------------------------------------------------------
# Controller tick
# --------------------------------------------------------------------------

def _make_controller(seed=3, windows=None, taskbar_top=None):
    renderer = FakeRenderer(size=(400.0, 300.0), windows=windows or [],
                            taskbar_top=taskbar_top)
    world = core.SnowWorld(400.0, 300.0, rng=random.Random(seed))
    return Controller(world, renderer), world, renderer


def test_tick_feeds_windows_taskbar_and_presents_each_frame():
    win = core.Win(5, 40.0, 30.0, 160.0, 120.0)
    controller, world, renderer = _make_controller(windows=[win], taskbar_top=290.0)
    for _ in range(3):
        controller.tick(1.0 / 60.0)
    assert world.clock.now() == pytest.approx(3.0 / 60.0)
    assert world.order == [win]
    assert world.ground.top_y == pytest.approx(290.0)
    assert len(renderer.presented_frames) == 3
    assert all(frame is world for frame in renderer.presented_frames)


def test_paused_world_stops_presenting_and_freezes_the_clock():
    controller, world, renderer = _make_controller()
    controller.tick(1.0 / 60.0)
    assert len(renderer.presented_frames) == 1
    controller.handle_command("pause")
    frozen = world.clock.now()
    for _ in range(5):
        controller.tick(1.0 / 60.0)
    assert world.clock.now() == pytest.approx(frozen)
    assert len(renderer.presented_frames) == 1
    assert renderer.overlay_visibility[-1] is False


# --------------------------------------------------------------------------
# Command dispatch
# --------------------------------------------------------------------------

def test_pause_command_toggles_world_and_overlay_visibility():
    controller, world, renderer = _make_controller()
    controller.handle_command("pause")
    assert world.paused is True
    assert renderer.overlay_visibility == [False]
    controller.handle_command("pause")
    assert world.paused is False
    assert renderer.overlay_visibility == [False, True]


def test_amount_commands_change_the_target():
    controller, world, _ = _make_controller()
    for name in ("light", "medium", "heavy"):
        controller.handle_command(name)
        assert world.target_flakes == core.AMOUNTS[name]


def test_clear_command_empties_piles_but_keeps_flakes():
    controller, world, _ = _make_controller()
    pile = core.Pile(40.0, 30.0, 120.0, core.WINDOW_PILE_MAX)
    pile.h[:] = [3.0] * pile.count
    world.piles[5] = pile
    world.ground.h[:] = [2.0] * world.ground.count
    flake_ids = [id(f) for f in world.flakes]
    controller.handle_command("clear")
    assert all(h == 0.0 for h in pile.h)
    assert all(h == 0.0 for h in world.ground.h)
    assert [id(f) for f in world.flakes] == flake_ids


def test_quit_command_calls_renderer_and_stops_the_tick():
    controller, world, renderer = _make_controller()
    controller.handle_command("quit")
    assert renderer.quit_calls == 1
    controller.tick(1.0 / 60.0)
    assert renderer.quit_calls == 1
    assert renderer.presented_frames == []
    assert world.clock.now() == pytest.approx(0.0)


def test_unknown_command_is_rejected():
    controller, _, _ = _make_controller()
    with pytest.raises(ValueError):
        controller.handle_command("explode")
