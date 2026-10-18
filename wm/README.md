# flat-wm

The window manager of Flat. It is a fork of [kwm] (commit
`ee81d6e352250a0e97d31cc0e93870416aa6c479`) by kewuaa and contributors, a
scroller window manager implementing the `river-window-management-v1`
protocol. It runs on the [Flat compositor](../compositor), and on river
without the features that need `river-window-scale-v1`.

## Features

- Scroller layout: each row is a strip of columns that scrolls sideways.
- Workspaces: up to 9 per output, each one a plane of rows. On Flat they
  are published through `river-workspace-v1`, so bars that read
  `ext-workspace-v1`, such as DankMaterialShell, list and switch them.
  Empty workspaces other than the shown one and the first one are marked
  hidden.
- Overview: zooms out of the workspace (needs `river-window-scale-v1`),
  falls back to a grid of the rows on other compositors.
- Touchpad gestures, read from libinput directly (the user must be in the
  `input` group): swipe through columns, rows and workspaces.
- Animations for focus, swaps, width changes, row and workspace switches,
  opening and closing windows.
- Window rules, modes with their own bindings, swallowing, a status bar,
  compile-time and runtime configuration.

See [`config.def.zon`](config.def.zon) for every option.

## Building

Dependencies: zig 0.16, wayland, xkbcommon, pixman and fcft (for the bar),
wayland-protocols (compile only).

```
zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```

- `-Dconfig`: the compiled-in config (default `config.zon`, copied from
  `config.def.zon` if missing)
- `-Dbar`, `-Dbackground`: enable the status bar / the solid background
- `-Dkwim`: start [kwim] for input device configuration (default `true`)

## Usage

```
flat -c flat-wm
```

The runtime config is read from `$XDG_CONFIG_HOME/flat-wm/config.zon`
(`~/.config/flat-wm/config.zon`). See `flat-wm(1)`.

## License

GPL-3.0, see [LICENSE](LICENSE). The protocols in `protocol/` keep the
licenses stated in their copyright blocks. Most of the code was written by
the kwm authors, see `../NOTICE.md` for the origin and the changes.

[kwm]: https://github.com/kewuaa/kwm
[kwim]: https://github.com/kewuaa/kwim
