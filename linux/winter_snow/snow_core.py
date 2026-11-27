"""Deterministic snow simulation core — no GUI imports.

This is a direct Python translation of windows/Program.cs L19-347 (Cfg through
SnowWorld).  Coordinates are logical pixels with y growing downwards.  Randomness
and time are injected so a world is fully reproducible in tests.
"""

import math
import random
from typing import Dict, List, Optional  # noqa: F401 (used in type comments)


class Cfg:
    """Tunables, mirroring the Windows ``static class Cfg``."""

    TARGET_FLAKES = 260
    COL_W = 3.0
    WINDOW_PILE_MAX = 16.0
    GROUND_PILE_MAX = 34.0
    TASKBAR_PILE_MAX = 18.0
    TASKBAR_GAIN = 2.0
    GRAVITY = 900.0
    POLL_INTERVAL = 1.0 / 30.0
    MAX_CLUMP = 900
    FALL_SPEED = 1.5
    FLAKES_IN_FRONT = True
    IN_FRONT_FRACTION = 0.4
    FRAME_MS = 16
    FLING_IGNORE_S = 0.35
    GROUND_ID = -2


# Module-level aliases keep the flat constant names used by the spec available.
TARGET_FLAKES = Cfg.TARGET_FLAKES
COL_W = Cfg.COL_W
WINDOW_PILE_MAX = Cfg.WINDOW_PILE_MAX
GROUND_PILE_MAX = Cfg.GROUND_PILE_MAX
TASKBAR_PILE_MAX = Cfg.TASKBAR_PILE_MAX
TASKBAR_GAIN = Cfg.TASKBAR_GAIN
GRAVITY = Cfg.GRAVITY
POLL_INTERVAL = Cfg.POLL_INTERVAL
MAX_CLUMP = Cfg.MAX_CLUMP
FALL_SPEED = Cfg.FALL_SPEED
FLAKES_IN_FRONT = Cfg.FLAKES_IN_FRONT
IN_FRONT_FRACTION = Cfg.IN_FRONT_FRACTION
FRAME_MS = Cfg.FRAME_MS
FLING_IGNORE_S = Cfg.FLING_IGNORE_S
GROUND_ID = Cfg.GROUND_ID

AMOUNTS = {"light": 120, "medium": 260, "heavy": 500}


class Layer:
    """One depth band: far/small/faint/slow through near/big/bright/fast."""

    def __init__(self, size_lo, size_hi, speed_lo, speed_hi, alpha_lo, alpha_hi,
                 sway_lo, sway_hi, wind):
        self.size_lo = size_lo
        self.size_hi = size_hi
        self.speed_lo = speed_lo
        self.speed_hi = speed_hi
        self.alpha_lo = alpha_lo
        self.alpha_hi = alpha_hi
        self.sway_lo = sway_lo
        self.sway_hi = sway_hi
        self.wind = wind


LAYERS = (
    Layer(1.8, 3.0, 22, 38, 0.30, 0.50, 5, 10, 0.5),
    Layer(3.0, 4.8, 40, 65, 0.60, 0.80, 9, 16, 0.8),
    Layer(4.8, 7.5, 70, 105, 0.85, 1.0, 14, 24, 1.1),
)
Cfg.LAYERS = LAYERS

LAYER_CUTS = (0.40, 0.68)  # 40% far, 28% middle, 32% near


def wind_at(t):
    """A few sines at different frequencies add up to gusty wind."""
    return (14.0 * math.sin(t * 0.11)
            + 9.0 * math.sin(t * 0.37 + 1.3)
            + 6.0 * math.sin(t * 0.9 + 0.4))


class Clock:
    """Injectable simulation clock (seconds)."""

    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def advance(self, dt):
        self.t += dt


class Flake:
    def __init__(self):
        self.x = 0.0
        self.y = 0.0
        self.vx = 0.0
        self.vy = 0.0
        self.size = 4.0
        self.alpha = 1.0
        self.sway_amp = 0.0
        self.sway_freq = 1.0
        self.phase = 0.0
        self.wind_factor = 1.0
        self.layer = 0          # 0 far, 1 middle, 2 near
        self.clump = False      # sliding off a surface (gravity applies)
        self.in_front = False   # falls in front of windows
        self.ignore_id = -1     # don't land right back on the surface it came from
        self.ignore_until = 0.0


class Win:
    def __init__(self, id, l, t, r, b):
        self.id = id
        self.l = l
        self.t = t
        self.r = r
        self.b = b

    @property
    def width(self):
        return self.r - self.l

    def contains(self, x, y):
        return self.l <= x < self.r and self.t <= y < self.b

    def __repr__(self):
        return "Win({}, {}, {}, {}, {})".format(self.id, self.l, self.t, self.r, self.b)


class Pile:
    """A height map drawn as a smooth white mound.  ``top_y`` is its edge."""

    SPREAD = ((0, 1.0), (-1, 0.75), (1, 0.75), (-2, 0.45), (2, 0.45),
              (-3, 0.2), (3, 0.2))

    def __init__(self, min_x, top_y, width, max_h):
        self.min_x = min_x
        self.top_y = top_y
        self.width = width
        self.max_h = max_h
        self.count = max(1, math.ceil(width / COL_W))
        self.h = [0.0] * self.count
        self.caps = [0.0] * self.count
        self.occ = [False] * self.count
        self.dirty = False
        for i in range(self.count):
            edge_dist = min(i + 0.5, self.count - i - 0.5) * COL_W
            t = min(1.0, edge_dist / (max_h * 2.2))
            self.caps[i] = max_h * math.sqrt(t)  # taper at both ends

    @property
    def total(self):
        return sum(self.h)

    def col(self, x):
        c = math.floor((x - self.min_x) / COL_W)
        return c if 0 <= c < self.count else -1

    def col_x(self, c):
        return self.min_x + (c + 0.5) * COL_W

    def surface(self, c):
        return self.top_y - self.h[c]

    def add(self, c, amount):
        for offset, weight in self.SPREAD:
            i = c + offset
            if i < 0 or i >= self.count or self.occ[i]:
                continue
            self.h[i] = min(self.caps[i], self.h[i] + amount * weight)
        self.dirty = True

    def relax(self):
        """Let snow slump sideways where the slope is too steep."""
        if not self.dirty:
            return
        moved = False
        for i in range(self.count - 1):
            if self.occ[i] or self.occ[i + 1]:
                continue
            d = self.h[i] - self.h[i + 1]
            if abs(d) > 1.0:
                m = (abs(d) - 1.0) * 0.3 * math.copysign(1.0, d)
                self.h[i] = min(self.caps[i], max(0.0, self.h[i] - m))
                self.h[i + 1] = min(self.caps[i + 1], max(0.0, self.h[i + 1] + m))
                if abs(m) > 0.02:
                    moved = True
        self.dirty = moved

    def clear(self):
        for i in range(self.count):
            self.h[i] = 0.0
        self.dirty = True


def _clamp(value, lo, hi):
    return lo if value < lo else (hi if value > hi else value)


class SnowWorld:
    """All simulation state.  ``rng`` and ``clock`` are injectable for tests."""

    def __init__(self, w, h, rng=None, clock=None, cfg=None):
        self.w = float(w)
        self.h = float(h)
        self.rng = rng if rng is not None else random.Random()
        self.clock = clock if clock is not None else Clock()
        self.cfg = cfg if cfg is not None else Cfg
        self.flakes = []                  # type: List[Flake]
        self._pool = []                   # type: List[Flake]
        self.piles = {}                   # type: Dict[int, Pile]
        self.last_rect = {}               # type: Dict[int, Win]
        self.order = []                   # type: List[Win]
        self.ground = None                # type: Optional[Pile]
        self.ground_is_taskbar = False
        self.target_flakes = self.cfg.TARGET_FLAKES
        self.paused = False
        self._poll_acc = 0.0
        self._reset_ground(self.h, False)
        for _ in range(self.target_flakes):
            self.spawn_flake()

    # -- geometry / ground --------------------------------------------------

    def resize(self, w, h):
        self.w = float(w)
        self.h = float(h)
        self._reset_ground(self.h, False)

    def _reset_ground(self, top, taskbar):
        if self.ground is not None:
            self.release(self.ground, 0.0, 0.0, GROUND_ID)
        self.ground_is_taskbar = taskbar
        max_h = self.cfg.TASKBAR_PILE_MAX if taskbar else self.cfg.GROUND_PILE_MAX
        self.ground = Pile(0.0, top, self.w, max_h)

    def reset_ground(self, top, taskbar):
        """Public alias used by the platform layer / tests."""
        self._reset_ground(top, taskbar)

    def clear_all(self):
        for pile in self.piles.values():
            pile.clear()
        self.ground.clear()

    # -- flake pool ---------------------------------------------------------

    def obtain(self):
        flake = self._pool.pop() if self._pool else Flake()
        self.flakes.append(flake)
        return flake

    def recycle(self, i):
        self._pool.append(self.flakes[i])
        self.flakes[i] = self.flakes[-1]
        self.flakes.pop()

    def spawn_flake(self, y=None):
        flake = self.obtain()
        r = self.rng.uniform(0.0, 1.0)
        li = 0 if r < LAYER_CUTS[0] else (1 if r < LAYER_CUTS[1] else 2)
        layer = LAYERS[li]
        flake.layer = li
        flake.clump = False
        flake.in_front = (bool(self.cfg.FLAKES_IN_FRONT) and li == 0
                          and self.rng.uniform(0.0, 1.0) < self.cfg.IN_FRONT_FRACTION)
        flake.ignore_id = -1
        flake.ignore_until = 0.0
        flake.size = self.rng.uniform(layer.size_lo, layer.size_hi)
        flake.vx = 0.0
        flake.vy = self.rng.uniform(layer.speed_lo, layer.speed_hi) * self.cfg.FALL_SPEED
        flake.sway_amp = self.rng.uniform(layer.sway_lo, layer.sway_hi)
        flake.sway_freq = self.rng.uniform(0.6, 1.6)
        flake.phase = self.rng.uniform(0.0, 6.28)
        flake.wind_factor = layer.wind
        flake.alpha = self.rng.uniform(layer.alpha_lo, layer.alpha_hi)
        flake.x = self.rng.uniform(-40.0, self.w + 40.0)
        flake.y = y if y is not None else -self.rng.uniform(2.0, 30.0)
        return flake

    def spawn_clump(self, x, y, vx, vy, source_id):
        flake = self.obtain()
        flake.clump = True
        flake.in_front = False
        flake.layer = 2
        flake.size = self.rng.uniform(2.5, 5.0)
        flake.alpha = 0.95
        flake.vx = vx
        flake.vy = vy
        flake.ignore_id = source_id
        flake.ignore_until = self.clock.now() + self.cfg.FLING_IGNORE_S
        flake.x = x
        flake.y = y
        return flake

    def release(self, pile, vx, vy, source_id):
        """Turn a pile into falling clumps; (vx, vy) is the source's velocity."""
        total = pile.total
        if total > 0.5:
            budget = max(0, self.cfg.MAX_CLUMP - len(self.flakes) + self.target_flakes)
            k = min(1.0, budget / max(1.0, total / 3.5))
            fx = _clamp(vx * 0.5, -900.0, 900.0)
            fy = _clamp(vy * 0.4, -500.0, 300.0)
            for c in range(pile.count):
                if pile.h[c] <= 0.6:
                    continue
                amount = pile.h[c] / 3.5 * k
                while amount > 0:
                    if amount < 1.0 and self.rng.uniform(0.0, 1.0) > amount:
                        break
                    self.spawn_clump(pile.col_x(c) + self.rng.uniform(-1.5, 1.5),
                                     pile.top_y - self.rng.uniform(0.0, pile.h[c]),
                                     fx + self.rng.uniform(-40.0, 40.0),
                                     fy - self.rng.uniform(10.0, 80.0), source_id)
                    amount -= 1.0
        pile.clear()

    def normal_count(self):
        return sum(1 for f in self.flakes if not f.clump)

    def set_amount(self, name):
        if name not in AMOUNTS:
            raise ValueError("unknown snow amount: {!r}".format(name))
        self.target_flakes = AMOUNTS[name]

    def set_paused(self, paused):
        self.paused = bool(paused)

    # -- per-frame update ---------------------------------------------------

    def update(self, dt, windows, taskbar_top=None):
        if self.paused:
            return
        self.clock.advance(dt)
        self._poll_acc += dt
        if self._poll_acc >= self.cfg.POLL_INTERVAL:
            self.poll_windows(self._poll_acc, windows, taskbar_top)
            self._poll_acc = 0.0
        self.step_flakes(dt)

    def poll_windows(self, dt, windows, taskbar_top=None):
        ground_top = self.h if taskbar_top is None else taskbar_top
        taskbar = taskbar_top is not None
        if (abs(ground_top - self.ground.top_y) > 1
                or taskbar != self.ground_is_taskbar):
            self._reset_ground(ground_top, taskbar)

        alive = set(w.id for w in windows)
        gone = [key for key in self.piles if key not in alive]
        for key in gone:
            self.release(self.piles[key], 0.0, 0.0, key)
            del self.piles[key]
            self.last_rect.pop(key, None)

        for r in windows:
            pile = self.piles.get(r.id)
            old = self.last_rect.get(r.id)
            if pile is not None and old is not None:
                if abs(old.width - r.width) > 0.5:
                    self.release(pile, 0.0, 0.0, r.id)
                    self.piles[r.id] = Pile(r.l, r.t, r.width, self.cfg.WINDOW_PILE_MAX)
                elif abs(old.l - r.l) > 0.3 or abs(old.t - r.t) > 0.3:
                    vx = (r.l - old.l) / dt
                    vy = (r.t - old.t) / dt
                    pile.min_x = r.l
                    pile.top_y = r.t
                    self.release(pile, vx, vy, r.id)
            else:
                self.piles[r.id] = Pile(r.l, r.t, r.width, self.cfg.WINDOW_PILE_MAX)
            self.last_rect[r.id] = r

        self.order = list(windows)
        self.compute_occlusion()
        for pile in self.piles.values():
            pile.relax()
        self.ground.relax()

    def compute_occlusion(self):
        """Columns hidden behind a window in front get no snow and aren't drawn."""
        for i, w in enumerate(self.order):
            pile = self.piles.get(w.id)
            if pile is None:
                continue
            for c in range(pile.count):
                x = pile.col_x(c)
                y = pile.top_y - 1.0
                occluded = x < 0.0 or x > self.w or y < 0.0
                if not occluded:
                    for j in range(i):
                        if self.order[j].contains(x, y):
                            occluded = True
                            break
                if occluded != pile.occ[c]:
                    pile.occ[c] = occluded
                    if occluded:
                        pile.h[c] = 0.0
                    pile.dirty = True

        # The taskbar is always in front of windows; the plain screen bottom is not.
        for c in range(self.ground.count):
            occluded = False
            if not self.ground_is_taskbar:
                x = self.ground.col_x(c)
                y = self.ground.top_y - 1.0
                for w in self.order:
                    if w.contains(x, y):
                        occluded = True
                        break
            if occluded != self.ground.occ[c]:
                self.ground.occ[c] = occluded
                if occluded:
                    self.ground.h[c] = 0.0
                self.ground.dirty = True

    def step_flakes(self, dt):
        wind = wind_at(self.clock.now())
        t = self.clock.now()
        normal = 0
        for i in range(len(self.flakes) - 1, -1, -1):
            f = self.flakes[i]
            prev_y = f.y
            if f.clump:
                f.vy += self.cfg.GRAVITY * dt
                f.vx *= max(0.0, 1.0 - 1.2 * dt)
                f.x += f.vx * dt
                f.y += f.vy * dt
            else:
                sway = math.sin(t * f.sway_freq + f.phase) * f.sway_amp
                f.x += (wind * f.wind_factor + sway) * dt
                f.y += f.vy * dt
                if f.x < -40.0:
                    f.x += self.w + 80.0
                elif f.x > self.w + 40.0:
                    f.x -= self.w + 80.0

            gone = False
            if f.y > prev_y:
                # Window tops, front to back (in-front flakes skip them).
                if not f.in_front:
                    for w in self.order:
                        pile = self.piles.get(w.id)
                        if pile is None:
                            continue
                        if f.clump and w.id == f.ignore_id and t < f.ignore_until:
                            continue
                        c = pile.col(f.x)
                        if c < 0 or pile.occ[c]:
                            continue
                        surface = pile.surface(c)
                        if prev_y <= surface and f.y > surface:
                            pile.add(c, 1.6 if f.clump else f.size * 0.16)
                            gone = True
                            break
                # Then the taskbar / bottom of the screen.
                if not gone:
                    c = self.ground.col(f.x)
                    if c >= 0 and f.y > self.ground.surface(c):
                        if not self.ground.occ[c]:
                            gain = self.cfg.TASKBAR_GAIN if self.ground_is_taskbar else 1.0
                            self.ground.add(c, (1.6 if f.clump else f.size * 0.12) * gain)
                        gone = True

            if not gone:
                # Flakes that fall behind a window disappear.
                if not f.in_front:
                    for w in self.order:
                        if w.contains(f.x, f.y):
                            gone = True
                            break
                if f.y > self.h + 20.0:
                    gone = True
                if f.clump and (f.x < -80.0 or f.x > self.w + 80.0):
                    gone = True

            if gone:
                self.recycle(i)
            elif not f.clump:
                normal += 1

        deficit = min(6, self.target_flakes - normal)
        for _ in range(max(0, deficit)):
            self.spawn_flake()
