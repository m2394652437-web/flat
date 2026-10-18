# Flat

A Wayland desktop in two programs:

- [`compositor/`](compositor): `flat`, the compositor, a fork of
  [river](https://codeberg.org/river/river) 0.5.0.
- [`wm/`](wm): `flat-wm`, the window manager, a fork of
  [kwm](https://github.com/kewuaa/kwm).

They talk through river's Wayland protocols, plus `river-window-scale-v1`,
which Flat adds for the zoomed out overview and the close animation.

## Building

```
cd compositor && zig build -Doptimize=ReleaseSafe -Dxwayland=true --prefix ~/.local install
cd wm && zig build -Doptimize=ReleaseSafe --prefix ~/.local install
```

Start the session with `flat -c flat-wm`, or pick "Flat" in the display
manager (`wm/contrib/flat.desktop`).

## License

Flat is free software under the GNU General Public License version 3, see
[LICENSE](LICENSE). Most of its code was written by the river and kwm
authors. [NOTICE.md](NOTICE.md) records the origin, the copyright holders
and the changes.
