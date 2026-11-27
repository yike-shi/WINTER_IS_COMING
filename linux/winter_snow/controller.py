"""Renderer contract and GUI-independent controller.

The controller is the only place that drives the world from platform events, so
it can be tested with a plain in-memory renderer instead of a real display.
"""

from typing import List, Optional, Protocol, Tuple, runtime_checkable

from winter_snow.snow_core import AMOUNTS, Win

COMMANDS = ("pause", "light", "medium", "heavy", "clear", "quit")


@runtime_checkable
class Renderer(Protocol):
    """Everything the controller needs from a platform window."""

    def screen_size(self) -> Tuple[float, float]: ...

    def window_rects(self) -> List[Win]: ...

    def taskbar_top(self) -> Optional[float]: ...

    def present_frame(self, world) -> None: ...

    def set_overlay_visible(self, visible: bool) -> None: ...

    def set_overlay_geometry(self, x, y, w, h) -> None: ...

    def show_control_window(self) -> None: ...

    def quit(self) -> None: ...


class FakeRenderer:
    """A real in-memory renderer with scripted state and call records."""

    def __init__(self, size=(1024.0, 768.0), windows=None, taskbar_top=None,
                 control_choice="on_screen"):
        self.size = size
        self.windows = list(windows) if windows is not None else []
        self.taskbar_top_value = taskbar_top
        self.control_choice = control_choice
        self.presented_frames = []
        self.overlay_visibility = []
        self.overlay_geometry = []
        self.control_calls = 0
        self.control_choices = []
        self.quit_calls = 0

    def screen_size(self):
        return self.size

    def window_rects(self):
        return list(self.windows)

    def taskbar_top(self):
        return self.taskbar_top_value

    def present_frame(self, world):
        self.presented_frames.append(world)

    def set_overlay_visible(self, visible):
        self.overlay_visibility.append(bool(visible))

    def set_overlay_geometry(self, x, y, w, h):
        self.overlay_geometry.append((x, y, w, h))

    def show_control_window(self):
        self.control_calls += 1
        self.control_choices.append(self.control_choice)

    def quit(self):
        self.quit_calls += 1


class Controller:
    """Fetch platform state, step the world, present frames, dispatch commands."""

    def __init__(self, world, renderer):
        self.world = world
        self.renderer = renderer
        self.running = True

    def tick(self, dt):
        if not self.running:
            return
        rects = self.renderer.window_rects()
        taskbar = self.renderer.taskbar_top()
        self.world.update(dt, rects, taskbar)
        if not self.world.paused:
            self.renderer.present_frame(self.world)

    def handle_command(self, command):
        if command == "pause":
            self.world.set_paused(not self.world.paused)
            self.renderer.set_overlay_visible(not self.world.paused)
        elif command in AMOUNTS:
            self.world.set_amount(command)
        elif command == "clear":
            self.world.clear_all()
        elif command == "quit":
            self.renderer.quit()
            self.running = False
        else:
            raise ValueError("unknown command: {!r}".format(command))
