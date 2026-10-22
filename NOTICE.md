# Notice

Flat is a modified version of two GPL-3.0 programs. This file records where
the code comes from, who holds its copyright and what was changed, as section
5 of the GNU General Public License version 3 asks.

## compositor/: modified river

- Upstream: river, <https://codeberg.org/river/river>
- Taken from: version 0.5.0, commit `cc4a291b2b9375fe3d5fe5a64b6f510b463f888b`
- Copyright: © 2020-2026 The River Developers, Isaac Freund and the other
  river contributors, as stated in each file
- License: GPL-3.0-only for the source code, MIT for the protocols,
  CC-BY-SA-4.0 for the documentation, 0BSD for a few build files, as stated
  in each file; texts in `compositor/LICENSES/`

Every file changed from river has an extra line
`SPDX-FileCopyrightText: © 2026 CQZY (modified for Flat)`. New files carry
`SPDX-FileCopyrightText: © 2026 CQZY` only.

Changes, October 2026, by CQZY:

- Renamed the program to `flat`, the init file to `~/.config/flat/init`, the
  installed protocols to `flat-protocols`, the man page to `flat(1)`.
- Added the `river-window-scale-v1` protocol: windows rendered scaled
  (`set_scale`) and ghosts that keep the last frame of a closed window
  (`get_ghost`). Files: `protocol/river-window-scale-v1.xml`,
  `river/WindowScale.zig`, `river/WindowGhost.zig`, and changes in
  `river/Window.zig`, `river/WindowManager.zig`, `river/Output.zig`,
  `river/Scene.zig`, `river/Server.zig`, `river/main.zig`, `build.zig`,
  `build.zig.zon`, `doc/flat.1.scd`.
- Added the `river-workspace-v1` protocol: the window manager publishes its
  workspaces, which are shown to other clients through `ext-workspace-v1`.
  Files: `protocol/river-workspace-v1.xml`, `river/Workspaces.zig`,
  `river/Workspace.zig`, and changes in `river/Output.zig`,
  `river/Server.zig`, `build.zig`.
- Removed river's logo, CI files, code of conduct, contributing and
  packaging guides and README, which describe the river project. A new
  README was written.

## wm/: modified kwm

- Upstream: kwm, <https://github.com/kewuaa/kwm>
- Taken from: commit `ee81d6e352250a0e97d31cc0e93870416aa6c479`
  (2026-09-25)
- Copyright: kewuaa and the kwm contributors: nate zhou, benpz, Oleg
  Fedotov, Tuzu, Aaron Sowry, Ethan Long, Felix Gerling, Mason Remaley,
  Morten Klim Sørensen, ange, paul
- License: GPL-3.0, see `wm/LICENSE`. The protocols in `wm/protocol/` are
  copies of river's and are under MIT, as stated in each file.

The kwm sources have no per-file copyright lines. All files under `wm/`
except the new ones below may have been changed by CQZY between
2026-10-08 and 2026-10-18.

Changes, October 2026, by CQZY:

- Preset window widths.
- Removed the config preprocessor (`@if`, `@include`, `@define` macros):
  `config.zon` is plain ZON.
- Only the scroller layout is kept, the other layouts were removed.
- Workspaces: each one a plane of rows; tags became the rows.
- Overview, zoomed out with `river-window-scale-v1` when the compositor
  offers it.
- Workspaces published to bars through `river-workspace-v1`, for
  `ext-workspace-v1` clients such as DankMaterialShell.
- Touchpad gestures read from libinput: columns, rows (three fingers) and
  workspaces (four fingers).
- Animations for focus, swaps, width changes, rows, workspaces, opening
  windows, and closing windows through ghosts.
- The `center` action, the `center_single` scroller option, and config
  reload on `SIGUSR1`.
- `flat-config`, a terminal editor for `config.zon`.
- Renamed the program to `flat-wm`, the config directory to
  `~/.config/flat-wm/`, the man page to `flat-wm(1)`, the session file to
  `flat.desktop`.
- Removed kwm's logo, screenshot, CI files, package list, install scripts
  and README. A new README was written.

New files: `wm/protocol/river-window-scale-v1.xml` and
`wm/protocol/river-workspace-v1.xml` (MIT, © 2026 CQZY),
`wm/README.md`, `wm/contrib/flat.desktop`, `wm/src/flat_config/`.

## The rest

`README.md` and this file were written for Flat by CQZY. `LICENSE` is the
text of the GNU General Public License version 3.

Flat is not river and not kwm. Its authors are not responsible for it, and
problems with Flat should not be reported to them.
