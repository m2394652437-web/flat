<!--
SPDX-FileCopyrightText: © 2026 CQZY
SPDX-License-Identifier: GPL-3.0-only
-->

# Flat compositor

The Wayland compositor of Flat. It is a fork of [river] 0.5.0 (commit
`cc4a291b2b9375fe3d5fe5a64b6f510b463f888b`), a non-monolithic compositor:
window management is done by a separate program, here [`flat-wm`](../wm).

Flat keeps river's protocols, so it still speaks
`river-window-management-v1` and works with other river window managers.
It adds `river-window-scale-v1` (`protocol/river-window-scale-v1.xml`):

- `set_scale` renders a window scaled without resizing it, used for the
  zoomed out overview.
- `get_ghost` (version 2) keeps the last frame of a window after it closes,
  so the window manager can animate it away.

It also adds `river-workspace-v1` (`protocol/river-workspace-v1.xml`): the
window manager publishes its workspaces, and Flat shows them to other
clients through `ext-workspace-v1`. Bars such as DankMaterialShell list the
workspaces and switch them; Flat passes the switch back to the window
manager.

This is not river. Please do not report problems with Flat to the river
project.

## Building

Dependencies: zig 0.16, wayland, wayland-protocols, wlroots 0.20,
xkbcommon 1.12 or newer, libevdev, pixman, pkg-config, scdoc (optional, for
the man page).

```
zig build -Doptimize=ReleaseSafe -Dxwayland=true --prefix ~/.local install
```

## Usage

Run `flat`. On startup it runs `$XDG_CONFIG_HOME/flat/init`
(`~/.config/flat/init`) if it is executable, or the command given with
`-c`, for example `flat -c flat-wm`. See `flat(1)`.

## License

The source code is released under GPL-3.0-only, the protocols under MIT,
the documentation under CC-BY-SA-4.0. Every file carries its copyright and
license in SPDX form, the license texts are in `LICENSES/`. Files changed
from river say so in their copyright lines. See `../NOTICE.md`.

[river]: https://codeberg.org/river/river
