# Flat

English | [中文](README.zh-CN.md)

Flat is a scrolling Wayland desktop made of two programs:

- [`compositor/`](compositor): `flat`, the compositor, a fork of
  [river](https://codeberg.org/river/river) 0.5.0.
- [`wm/`](wm): `flat-wm`, the window manager, a fork of
  [kwm](https://github.com/kewuaa/kwm), and `flat-config`, a terminal
  editor for its configuration.

The compositor draws and handles input. The window manager decides where
windows go. They talk through river's Wayland protocols.

![Flat desktop: an editor and two terminals in one row](images/desktop.png)

## Features

- **Scroller layout.** Each row is a strip of columns that scrolls sideways.
  A lone window can sit in the middle of the screen (`center_single`).
- **Workspaces.** Up to 9 per output, each one a plane of rows. Bars that
  read `ext-workspace-v1`, such as DankMaterialShell, list and switch them.
- **Overview.** Zooms out of the workspace to show every window.
- **Touchpad gestures.** Three fingers move through columns and rows, four
  fingers through workspaces.
- **Animations** for focus, swaps, width changes, row and workspace
  switches, opening and closing windows.
- **Window rules, modes** with their own bindings, swallowing, a status bar.
- **`flat-config`**, a TUI that edits the configuration in place and reloads
  the running window manager.

Two protocols are added to river's: `river-window-scale-v1` renders a window
scaled (for the overview) and keeps the last frame of a closed window (for
the close animation). `river-workspace-v1` lets the window manager publish
its workspaces, which the compositor passes on through `ext-workspace-v1`.

![The overview: rows of windows, zoomed out](images/overview.png)

## Requirements

- **zig 0.16.** Zig 0.17 does not build Flat, nor upstream river. If your
  system zig is newer, download 0.16 from
  [ziglang.org](https://ziglang.org/download/) and point `ZIG` at it (see
  below).
- wayland, wayland-protocols, wlroots 0.20, xkbcommon 1.12 or newer,
  libevdev, libinput, udev, pixman, fcft, pkg-config.
- scdoc, optional, for the man pages.
- At run time: a terminal (`foot` in the default bindings), a launcher
  (`wmenu-run`), and for X11 programs Xwayland or `xwayland-satellite`.

The touchpad gestures read libinput directly, so your user must be in the
`input` group.

## Building and installing

```
./reinstall.sh
```

This builds both programs and installs `flat`, `flat-wm` and `flat-config`
to `~/.local`.

- `ZIG=/path/to/zig-0.16/zig ./reinstall.sh` uses that zig instead of the
  one in `$PATH`.
- `PREFIX=/usr/local ./reinstall.sh` installs elsewhere.
- `--if-changed` does nothing when no source file changed since the last
  install.
- The build log goes to `~/.local/state/flat/reinstall.log`.

A running session keeps its old binaries until you log in again, so it is
safe to reinstall from inside Flat.

The same by hand:

```
cd compositor && zig build -Doptimize=ReleaseSafe -Dxwayland=true --prefix ~/.local install
cd wm && zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```

Build options of each program are listed in
[`compositor/README.md`](compositor/README.md) and
[`wm/README.md`](wm/README.md).

## Running

From a TTY:

```
flat -c flat-wm
```

From a display manager: the install puts `flat.desktop` in
`~/.local/share/wayland-sessions/`. Most display managers only read
`/usr/share/wayland-sessions/`, so copy it there:

```
sudo cp ~/.local/share/wayland-sessions/flat.desktop /usr/share/wayland-sessions/
```

## Configuration

flat-wm reads `~/.config/flat-wm/config.zon` (or
`$XDG_CONFIG_HOME/flat-wm/config.zon`). It is plain
[ZON](https://ziglang.org/documentation/master/#ZON). You only write the
values you want to change; everything else keeps its default.
[`wm/config.def.zon`](wm/config.def.zon) lists every option with comments.

### flat-config

```
flat-config
```

It opens the configuration as a tree. Bold names are set in your file, gray
ones use the default. If the file does not exist, it is created from the
default.

![flat-config](images/flat-config.png)

| Key | Action |
| :--- | :--- |
| `j` `k` `↑` `↓` | move |
| `l` `→` / `h` `←` | open / close a group, go to the parent |
| `Enter` `e` | edit: type a value, pick from a list, or toggle |
| `Space` | toggle a switch, open or close a group |
| `E` | edit the value as raw ZON |
| `x` | set to null, or give a null value one |
| `r` | reset: remove the value from the file and use the default |
| `a` / `y` / `d` | add / duplicate / delete a list item |
| `J` `K` | move a list item |
| `/` `n` `N` | find, next, previous |
| `u` `Ctrl-r` | undo, redo |
| `w` `Ctrl-s` | save |
| `q` | quit |
| `?` | all keys |

- Only the value you change is rewritten. Comments and layout stay.
- Key and pointer bindings are grouped by mode, then by modifiers (Super,
  Alt, ...). Pressing `a` on a group adds a binding with that mode and those
  modifiers.
- Changing a number or a string offers to change the other places in the
  file that hold the same value, so one width or gap can be kept in step.
- Saving checks the file with flat-wm's own parser and refuses a file it
  would reject. The first save keeps the original as `config.zon.bak`.
- After saving, flat-config tells the running flat-wm to reload.
- Rows on the cursor's level are shaded, and so are the rows under the
  cursor. The top level is not shaded. Set the colors with
  `-sibling-bg COLOR` and `-child-bg COLOR`, or `$FLAT_CONFIG_SIBLING_BG`
  and `$FLAT_CONFIG_CHILD_BG`. COLOR is a 256-color index (default 236 and
  234), `#rrggbb`, or `none`.

### Reloading by hand

Press `Mod4-Shift-r`, or send `SIGUSR1`:

```
pkill -USR1 -x flat-wm
```

## Default key bindings

`Mod4` is the Super (Windows) key.

| Keys | Action |
| :--- | :--- |
| `Mod4-Shift-Return` | open a terminal (`foot`) |
| `Mod4-p` | open the launcher (`wmenu-run`) |
| `Mod4-Shift-c` | close the window |
| `Mod4-j` `Mod4-k` | focus the next / previous window |
| `Mod4-Shift-j` `Mod4-Shift-k` | swap with the next / previous window |
| `Mod4-h` `Mod4-l` | narrower / wider window |
| `Mod4-Return` | scroll the window to the middle |
| `Mod4-c` | center the window; a floating one on the screen |
| `Mod4-f` | toggle floating |
| `Mod4-Shift-f` | toggle fullscreen |
| `Mod4-1` … `Mod4-9` | go to a workspace |
| `Mod4-Shift-1` … `Mod4-Shift-9` | send the window to a workspace |
| `Mod4-Shift-r` | reload the configuration |
| `Mod4-Shift-q` | quit |

The full list is in [`wm/doc/keybindings.md`](wm/doc/keybindings.md) and
`man flat-wm`. The overview has no default key; bind the `toggle_overview`
action to open it.

## Repository

```
compositor/      flat, the compositor (river fork)
wm/              flat-wm and flat-config (kwm fork)
  config.def.zon   every option, with comments
  src/flat_config/ the configuration TUI
reinstall.sh     build and install both
NOTICE.md        origin, copyright holders and changes
```

## License

Flat is free software under the GNU General Public License version 3, see
[LICENSE](LICENSE). Most of its code was written by the river and kwm
authors. [NOTICE.md](NOTICE.md) records the origin, the copyright holders
and the changes.

Flat is not river and not kwm. Please do not report problems with Flat to
those projects.
