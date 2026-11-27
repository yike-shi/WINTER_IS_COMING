"""Behaviour tests for the deterministic snow simulation core.

These are the Linux counterpart of windows/Program.cs L19-347.  The core must
stay free of GUI imports so it can be tested without a display.
"""

import math
import random

import pytest

from winter_snow import snow_core as core


# --------------------------------------------------------------------------
# Configuration / constants (mirror of Windows Cfg)
# --------------------------------------------------------------------------

def test_config_constants_mirror_windows_cfg():
    assert core.Cfg.TARGET_FLAKES == 260
    assert core.Cfg.COL_W == 3.0
    assert core.Cfg.WINDOW_PILE_MAX == 16.0
    assert core.Cfg.GROUND_PILE_MAX == 34.0
    assert core.Cfg.TASKBAR_PILE_MAX == 18.0
    assert core.Cfg.TASKBAR_GAIN == 2.0
    assert core.Cfg.GRAVITY == 900.0
    assert core.Cfg.POLL_INTERVAL == pytest.approx(1.0 / 30.0)
    assert core.Cfg.MAX_CLUMP == 900
    assert core.Cfg.FALL_SPEED == 1.5
    assert core.Cfg.FLAKES_IN_FRONT is True
    assert core.Cfg.IN_FRONT_FRACTION == pytest.approx(0.4)
    assert core.Cfg.FRAME_MS == 16
    assert core.Cfg.GROUND_ID == -2


def test_module_constants_agree_with_cfg():
    expected = {
        "TARGET_FLAKES": 260,
        "COL_W": 3.0,
        "WINDOW_PILE_MAX": 16.0,
        "GROUND_PILE_MAX": 34.0,
        "TASKBAR_PILE_MAX": 18.0,
        "TASKBAR_GAIN": 2.0,
        "GRAVITY": 900.0,
        "POLL_INTERVAL": 1.0 / 30.0,
        "MAX_CLUMP": 900,
        "FALL_SPEED": 1.5,
        "FLAKES_IN_FRONT": True,
        "IN_FRONT_FRACTION": 0.4,
        "FRAME_MS": 16,
        "GROUND_ID": -2,
    }
    for name, value in expected.items():
        assert getattr(core, name) == value


def test_amounts_and_layers_mirror_windows():
    assert core.AMOUNTS == {"light": 120, "medium": 260, "heavy": 500}
    assert len(core.LAYERS) == 3
    expected = [
        (1.8, 3.0, 22, 38, 0.30, 0.50, 5, 10, 0.5),
        (3.0, 4.8, 40, 65, 0.60, 0.80, 9, 16, 0.8),
        (4.8, 7.5, 70, 105, 0.85, 1.0, 14, 24, 1.1),
    ]
    for layer, values in zip(core.LAYERS, expected):
        got = (layer.size_lo, layer.size_hi, layer.speed_lo, layer.speed_hi,
               layer.alpha_lo, layer.alpha_hi, layer.sway_lo, layer.sway_hi,
               layer.wind)
        assert got == pytest.approx(values)


# --------------------------------------------------------------------------
# Small value types
# --------------------------------------------------------------------------

def test_win_width_and_contains_are_half_open():
    w = core.Win(5, 10.0, 20.0, 60.0, 80.0)
    assert w.width == pytest.approx(50.0)
    assert w.contains(10.0, 20.0) is True
    assert w.contains(59.9, 79.9) is True
    assert w.contains(60.0, 20.0) is False
    assert w.contains(10.0, 80.0) is False
    assert w.contains(9.9, 20.0) is False


def test_clock_advances_and_reports_now():
    clock = core.Clock()
    assert clock.now() == pytest.approx(0.0)
    clock.advance(0.25)
    assert clock.now() == pytest.approx(0.25)
    clock.advance(0.75)
    assert clock.now() == pytest.approx(1.0)


def test_wind_formula_and_bound():
    assert core.wind_at(0.0) == pytest.approx(
        9.0 * math.sin(1.3) + 6.0 * math.sin(0.4)
    )
    for t in (0.0, 0.5, 1.0, 7.25, 100.0, 1000.0):
        assert abs(core.wind_at(t)) <= 29.0


# --------------------------------------------------------------------------
# Pile: caps, spread, occlusion and relaxation
# --------------------------------------------------------------------------

def test_pile_count_and_tapered_caps():
    p = core.Pile(0.0, 10.0, 30.0, 16.0)
    assert p.count == 10
    assert p.caps[0] == pytest.approx(16.0 * math.sqrt(1.5 / (16.0 * 2.2)))
    assert p.caps[0] == pytest.approx(p.caps[-1])
    assert p.caps[5] > p.caps[0]


def test_pile_add_spreads_with_windows_weights():
    p = core.Pile(0.0, 10.0, 30.0, 16.0)
    p.add(5, 1.0)
    assert p.h[5] == pytest.approx(1.0)
    assert p.h[4] == pytest.approx(0.75)
    assert p.h[6] == pytest.approx(0.75)
    assert p.h[3] == pytest.approx(0.45)
    assert p.h[7] == pytest.approx(0.45)
    assert p.h[2] == pytest.approx(0.2)
    assert p.h[8] == pytest.approx(0.2)
    assert p.h[0] == pytest.approx(0.0)
    assert p.h[9] == pytest.approx(0.0)


def test_pile_add_clamps_to_caps_and_skips_occluded_columns():
    p = core.Pile(0.0, 10.0, 30.0, 16.0)
    p.occ[4] = True
    p.add(5, 1000.0)
    assert p.h[4] == pytest.approx(0.0)
    assert p.h[5] == pytest.approx(p.caps[5])
    assert p.surface(5) == pytest.approx(10.0 - p.caps[5])


def test_pile_relax_moves_steep_pairs_and_stops_when_flat():
    p = core.Pile(0.0, 10.0, 30.0, 16.0)
    p.h[5] = 5.0
    p.dirty = True
    p.relax()
    assert p.h[5] < 5.0
    assert p.h[4] > 0.0
    assert p.h[6] > 0.0
    for _ in range(50):
        p.relax()
    assert max(abs(p.h[i] - p.h[i + 1]) for i in range(p.count - 1)) < 1.1


def test_pile_clear_zeroes_all_heights():
    p = core.Pile(0.0, 10.0, 30.0, 16.0)
    p.add(5, 3.0)
    p.clear()
    assert all(h == 0.0 for h in p.h)


def test_pile_column_helpers():
    p = core.Pile(100.0, 20.0, 30.0, 16.0)
    assert p.col(100.0) == 0
    assert p.col(103.0) == 1
    assert p.col(99.0) == -1
    assert p.col(130.0) == -1
    assert p.col_x(0) == pytest.approx(101.5)
    p.h[2] = 4.0
    assert p.surface(2) == pytest.approx(16.0)


# --------------------------------------------------------------------------
# World initial state and deterministic spawning
# --------------------------------------------------------------------------

def test_initial_flakes_are_all_normal_and_start_above_screen():
    w = core.SnowWorld(400.0, 300.0, rng=random.Random(1))
    assert len(w.flakes) == core.TARGET_FLAKES
    assert all(not f.clump for f in w.flakes)
    assert all(f.y < 0.0 for f in w.flakes)
    assert w.normal_count() == core.TARGET_FLAKES


def test_layer_distribution_is_deterministic_for_a_seed():
    a = core.SnowWorld(800.0, 600.0, rng=random.Random(7))
    b = core.SnowWorld(800.0, 600.0, rng=random.Random(7))
    dist_a = tuple(sum(1 for f in a.flakes if f.layer == i) for i in range(3))
    dist_b = tuple(sum(1 for f in b.flakes if f.layer == i) for i in range(3))
    assert dist_a == dist_b
    assert sum(dist_a) == core.TARGET_FLAKES
    assert all(n > 0 for n in dist_a)
    # Regression lock computed from the faithful implementation (random.Random(7)).
    assert dist_a == (121, 60, 79)


def test_spawn_field_is_deterministic_and_in_range():
    a = core.SnowWorld(800.0, 600.0, rng=random.Random(11))
    b = core.SnowWorld(800.0, 600.0, rng=random.Random(11))
    fields = ("x", "y", "vx", "vy", "size", "alpha", "sway_amp",
              "sway_freq", "phase", "wind_factor", "layer", "clump", "in_front")

    def first(world):
        f = world.flakes[0]
        return tuple(getattr(f, name) for name in fields)

    assert first(a) == first(b)
    f = a.flakes[0]
    assert -40.0 <= f.x <= 840.0
    assert -30.0 <= f.y < 0.0
    assert f.vx == pytest.approx(0.0)
    layer = core.LAYERS[f.layer]
    assert layer.size_lo <= f.size <= layer.size_hi
    assert layer.speed_lo * core.FALL_SPEED <= f.vy <= layer.speed_hi * core.FALL_SPEED
    assert layer.alpha_lo <= f.alpha <= layer.alpha_hi
    assert f.alpha > 0.0
    assert 0.6 <= f.sway_freq <= 1.6
    assert f.wind_factor == pytest.approx(core.LAYERS[f.layer].wind)
    # Regression lock computed from the faithful implementation (random.Random(11)).
    assert first(a) == pytest.approx((
        410.47960235678886, -19.636716166070453, 0.0, 94.65789690088985,
        4.007590294944893, 0.6369320687709753, 12.259550490698413,
        1.107841273062271, 3.688776725177353, 0.8, 1, False, False,
    ))


def test_two_seeded_worlds_are_identical_after_120_steps():
    def snapshot(world):
        flakes = [(f.x, f.y, f.vx, f.vy, f.size, f.alpha, f.layer, f.clump,
                   f.in_front, f.ignore_id, f.ignore_until) for f in world.flakes]
        piles = [(key, list(pile.h)) for key, pile in sorted(world.piles.items())]
        return (world.clock.now(), flakes, piles, list(world.ground.h))

    windows = [
        core.Win(1, 50.0, 40.0, 200.0, 150.0),
        core.Win(2, 220.0, 60.0, 350.0, 160.0),
    ]
    a = core.SnowWorld(400.0, 300.0, rng=random.Random(42))
    b = core.SnowWorld(400.0, 300.0, rng=random.Random(42))
    for _ in range(120):
        a.update(1.0 / 60.0, windows, None)
        b.update(1.0 / 60.0, windows, None)
    assert snapshot(a) == snapshot(b)


# --------------------------------------------------------------------------
# Flake physics
# --------------------------------------------------------------------------

def test_clump_gravity_and_horizontal_drag():
    w = core.SnowWorld(200.0, 150.0, rng=random.Random(1))
    w.flakes.clear()
    f = core.Flake()
    f.clump = True
    f.x, f.y = 100.0, -100.0
    f.vx, f.vy = 100.0, 0.0
    w.flakes.append(f)

    dt = 0.1
    expected_vx = 100.0 * max(0.0, 1.0 - 1.2 * dt)
    w.step_flakes(dt)
    assert f.vy == pytest.approx(core.GRAVITY * dt)
    assert f.vx == pytest.approx(expected_vx)
    assert f.x == pytest.approx(100.0 + expected_vx * dt)
    assert f.y == pytest.approx(-100.0 + f.vy * dt)


def test_top_up_spawns_at_most_six_normal_flakes_per_step():
    w = core.SnowWorld(200.0, 150.0, rng=random.Random(2))
    w.flakes.clear()
    w.step_flakes(0.001)
    assert w.normal_count() == 6
    for _ in range(10):
        w.step_flakes(0.001)
    assert w.normal_count() == 66


def test_landing_adds_to_pile_and_recycles_flake():
    w = core.SnowWorld(120.0, 100.0, rng=random.Random(3))
    w.flakes.clear()
    f = core.Flake()
    f.x, f.y = 60.0, 90.0
    f.vy = 100.0
    f.size = 5.0
    w.flakes.append(f)
    before = w.ground.total
    for _ in range(12):
        w.step_flakes(0.01)
    assert w.ground.total > before
    assert w.normal_count() > 0  # the landed flake was recycled and topped up


def test_clump_is_culled_when_flung_offscreen():
    w = core.SnowWorld(100.0, 100.0, rng=random.Random(4))
    w.flakes.clear()
    f = core.Flake()
    f.clump = True
    f.x, f.y = 90.0, -50.0
    f.vx, f.vy = 2000.0, 0.0
    w.flakes.append(f)
    w.step_flakes(0.1)
    # The object is pooled and reused by the top-up, but it is no longer a clump.
    assert not any(existing.clump for existing in w.flakes)


def test_in_front_flake_ignores_window_tops():
    w = core.SnowWorld(200.0, 150.0, rng=random.Random(5))
    w.flakes.clear()
    win = core.Win(1, 50.0, 40.0, 150.0, 120.0)
    w.order = [win]
    w.piles[1] = core.Pile(50.0, 40.0, 100.0, core.WINDOW_PILE_MAX)
    before = w.piles[1].total

    front = core.Flake()
    front.x, front.y = 100.0, 39.0
    front.vy = 100.0
    front.in_front = True
    w.flakes.append(front)
    w.step_flakes(0.02)
    assert w.piles[1].total == pytest.approx(before)


def test_occlusion_zeros_hidden_pile_columns():
    w = core.SnowWorld(200.0, 150.0, rng=random.Random(6))
    front = core.Win(1, 50.0, 30.0, 120.0, 100.0)
    back = core.Win(2, 60.0, 50.0, 110.0, 120.0)
    front_pile = core.Pile(50.0, 30.0, 70.0, core.WINDOW_PILE_MAX)
    back_pile = core.Pile(60.0, 50.0, 50.0, core.WINDOW_PILE_MAX)
    for pile in (front_pile, back_pile):
        pile.h[:] = [5.0] * pile.count
    w.piles = {1: front_pile, 2: back_pile}
    w.order = [front, back]
    w.compute_occlusion()

    for c in range(back_pile.count):
        x = back_pile.col_x(c)
        if front.contains(x, back_pile.top_y - 1):
            assert back_pile.occ[c] is True
            assert back_pile.h[c] == pytest.approx(0.0)


# --------------------------------------------------------------------------
# Window polling: drag / resize / close / taskbar
# --------------------------------------------------------------------------

def _filled_pile(world, win, height=3.0):
    pile = core.Pile(win.l, win.t, win.width, core.WINDOW_PILE_MAX)
    pile.h[:] = [height] * pile.count
    world.piles[win.id] = pile
    world.last_rect[win.id] = win
    return pile


def test_drag_flings_pile_with_clamped_velocity_and_ignore_window():
    w = core.SnowWorld(300.0, 200.0, rng=random.Random(8))
    w.flakes.clear()
    old = core.Win(7, 100.0, 50.0, 180.0, 120.0)
    _filled_pile(w, old)
    new = core.Win(7, 160.0, 70.0, 240.0, 140.0)
    w.update(1.0 / 30.0, [new], None)

    clumps = [f for f in w.flakes if f.clump]
    assert clumps
    assert w.piles[7].total == pytest.approx(0.0)
    ignore_until = w.clock.now() + core.FLING_IGNORE_S
    for f in clumps:
        assert f.ignore_id == 7
        assert f.ignore_until == pytest.approx(ignore_until)
        # The fling is spawned during the poll, then stepped in the same frame:
        # vx *= 0.96 and vy += 900 * dt before we observe it.
        assert 825.0 <= f.vx <= 903.0       # clamp(1800 * 0.5) * 0.96 +/- 40 jitter
        assert 189.0 <= f.vy <= 261.0       # clamp(600 * 0.4) + 30, minus 10..80


def test_resize_releases_ground_with_zero_fling_velocity():
    w = core.SnowWorld(300.0, 200.0, rng=random.Random(9))
    w.flakes.clear()
    w.ground.h[:] = [5.0] * w.ground.count
    w.resize(300.0, 200.0)
    clumps = [f for f in w.flakes if f.clump]
    assert clumps
    assert all(-40.0 <= f.vx <= 40.0 for f in clumps)
    assert all(-80.0 <= f.vy <= -10.0 for f in clumps)
    assert w.ground.top_y == pytest.approx(200.0)


def test_width_change_releases_old_pile_and_starts_a_new_one():
    w = core.SnowWorld(300.0, 200.0, rng=random.Random(10))
    w.flakes.clear()
    old = core.Win(3, 100.0, 50.0, 180.0, 120.0)
    _filled_pile(w, old)
    resized = core.Win(3, 100.0, 50.0, 220.0, 120.0)
    w.update(1.0 / 30.0, [resized], None)
    assert w.piles[3].total == pytest.approx(0.0)
    assert w.piles[3].width == pytest.approx(120.0)
    assert any(f.clump and f.ignore_id == 3 for f in w.flakes)


def test_closed_window_releases_its_pile():
    w = core.SnowWorld(300.0, 200.0, rng=random.Random(11))
    w.flakes.clear()
    _filled_pile(w, core.Win(9, 100.0, 50.0, 180.0, 120.0))
    w.update(1.0 / 30.0, [], None)
    assert 9 not in w.piles
    assert 9 not in w.last_rect
    assert any(f.clump and f.ignore_id == 9 for f in w.flakes)


def test_taskbar_change_resets_ground_and_uses_taskbar_max():
    w = core.SnowWorld(300.0, 200.0, rng=random.Random(12))
    w.flakes.clear()
    w.update(1.0 / 30.0, [], None)
    assert w.ground.top_y == pytest.approx(200.0)
    assert w.ground_is_taskbar is False
    assert w.ground.max_h == pytest.approx(core.GROUND_PILE_MAX)

    w.update(1.0 / 30.0, [], 180.0)
    assert w.ground.top_y == pytest.approx(180.0)
    assert w.ground_is_taskbar is True
    assert w.ground.max_h == pytest.approx(core.TASKBAR_PILE_MAX)


# --------------------------------------------------------------------------
# Control state
# --------------------------------------------------------------------------

def test_pause_freezes_both_state_and_clock():
    w = core.SnowWorld(200.0, 150.0, rng=random.Random(13))
    w.set_paused(True)
    t0 = w.clock.now()
    positions = [(f.x, f.y) for f in w.flakes]
    w.update(1.0, [core.Win(1, 20.0, 20.0, 80.0, 80.0)], 100.0)
    assert w.clock.now() == pytest.approx(t0)
    assert [(f.x, f.y) for f in w.flakes] == positions
    assert w.order == []
    w.set_paused(False)
    w.update(1.0 / 60.0, [], None)
    assert w.clock.now() > t0


def test_clear_all_resets_piles_but_not_flakes():
    w = core.SnowWorld(200.0, 150.0, rng=random.Random(14))
    _filled_pile(w, core.Win(1, 20.0, 30.0, 90.0, 100.0))
    w.ground.h[:] = [2.0] * w.ground.count
    positions = [(f.x, f.y) for f in w.flakes]
    w.clear_all()
    assert all(h == 0.0 for h in w.piles[1].h)
    assert all(h == 0.0 for h in w.ground.h)
    assert [(f.x, f.y) for f in w.flakes] == positions


def test_set_amount_bounds_and_rejects_unknown_names():
    w = core.SnowWorld(200.0, 150.0, rng=random.Random(15))
    for name, expected in core.AMOUNTS.items():
        w.set_amount(name)
        assert w.target_flakes == expected
    with pytest.raises(ValueError):
        w.set_amount("blizzard")
    assert w.target_flakes == core.AMOUNTS["heavy"]


def test_core_has_no_gui_imports():
    import inspect
    source = inspect.getsource(core)
    for banned in ("import gi", "import Gtk", "import cairo", "from gi", "Xlib"):
        assert banned not in source
