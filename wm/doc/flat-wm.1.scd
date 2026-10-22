FLAT-WM(1) "flat-wm" "the window manager of Flat"

# NAME

flat-wm - the window manager of Flat, based on kwm

# SYNOPSIS

*flat-wm* [_OPTIONS_]++
*flat* -c flat-wm

# DESCRIPTION

_Flat_ is built on a fork of river, a non-monolithic Wayland compositor, it does not combine the compositor
and window manager into one program.

flat-wm is a DWM-like dynamic tiling window manager implementing the
river-window-management-v1 protocol.

See the default configuration file for detailed features.

# OPTIONS

*-h,-help*
	Print a help message and exit.

*-v,-version*
	Print the version number and exit.

*-c,-config*
	Specify custom configuration file path.


# KEYBINDINGS

flat-wm supports separate keybindings for each mode. Modes can be customized in the
configuration file.

## default mode
Mod4-Shift-r
	Reload the runtime user configuration.

Mod4-Shift-Escape
	Switch to the passthrough mode.

Mod4-Ctrl-f
	Switch to the floating mode.

Mod4-Shift-q
	Quit the session.

Mod4-Shift-c
	Close the window.

Mod4-Return
	Center the window.

Mod4-c
	Center the window, floating ones on the output.

Mod4-b
	Toggle the status bar.

Mod4-\[jk\]
	Focus the next/previous window.

Mod4-Ctrl-\[jk\]
	Focus the next/previous non-floating window.

Mod4-Shift-\[jk\]
	Swap with the next/previous non-floating window in the stack.

Mod4-\[.,\]
	Focus the next/previous output.

Mod4-Shift-\[.,\]
	Send window to the next/previous output.

Mod4-Shift-m
	Toggle fake fullscreen on the window.

Mod4-Shift-f
	Toggle fullscreen on the window.

Mod4-Shift-e
	Toggle maximize on the window.

Mod4-f
	Toggle floating on the window.

Mod4-Ctrl-s
	Toggle sticky on the window.

Mod4-a
	Toggle swallow on the window.

Mod4-Tab
	Switch to the previous tag.

Mod4-\[';\]
	Shift output's each tag to the next/previous occupied output tag.

Mod4-Shift-\[';\]
	Shift window's each tag to the next/previous unoccupied output tag.

Mod4-[1-9]
	Set the output tag.

Mod4-0
	Set all output tags as active.

Mod4-Ctrl-[1-9]
	Toggle the output tag.

Mod4-Shift-[1-9]
	Set the window tag.

Mod4-Shift-0
	Set the window with all tags.

Mod4-Ctrl-Shift-[1-9]
	Toggle the window tag.

Mod4-\[hl\]
	Decrease/increase the window width.

Mod1-Mod4-\[-=\]
	Decrease/increase the gaps.

Mod4-Shift-a
	Toggle auto swallow.

Mod4-p
	Spawn _wmenu-run_.

Mod4-Shift-Return
	Spawn _foot_.

## passthrough mode

Mod4-Shift-Escape
	Switch to the default mode.

## floating mode

Press any unbound keys will automatically switch to the default mode.

\[hjkl\]
	Move the floating window in the left/down/up/right direction by 10
	pixels.

Mod4-Ctrl-\[hl\]
	Decrease/increase the floating window width by 10 pixels.

Mod4-Ctrl-\[jk\]
	Increase/decrease the floating window height by 10 pixels.

Mod4-Shift-\[hjkl\]
	Snap the floating window to the left/bottom/top/right edge on the
	output.

## status bar

Button1
	Click on a tag label to set the output tag.++
	Click on mode label to switch to the default mode.++
	Click on title label to center the window.

Button2
	Click on a tag to toggle the window tag.++
	Click on status to spawn _foot(1)_.

Button3
	Click on a tag to toggle the output tag.

## mouse keybindings

Mod4-Button1
	Move the window while dragging.

Mod4-Button3
	Resize the window while dragging.

# CONFIGURATION

flat-wm supports both compile-time and runtime configuration.

Default configuration is usually installed to one of the following paths:

	/usr/share/doc/flat-wm/config.zon

	/usr/local/share/doc/flat-wm/config.zon

Below are some examples on configurable settings:

- *Startup commands*++
Commands to run when starting flat-wm.

- *Bar*++
Change bar position and fonts.++
Choose status among static text, stdin, and fifo.

- *Input devices* ++
There is an input device manager for _river_ separated from _flat-wm_ called
_kwim(1)_, implementing the river-input-management-v1 protocol and/or related
protocols in order to configure input devices independent of window manager.
When built with the `-Dkwim` option (defaults to `true`), _flat-wm_ will call _kwim_
automatically at startup. You can also run _kwim_ to list input devices or apply
a single rule on demand.

- *Keybindings*++
Change keybindings in each mode, and add custom modes.

- *Rules*++
Match windows by app_id or title with regex support.++
Set tag, floating, dimension, decoration, swallow and scroller behaviors.

## Compile Time

Make custom modifications in config.zon (if -Dconfig is not specified).

## Runtime

flat-wm searches for a user configuration in the following paths:

	$XDG_CONFIG_HOME/flat-wm/config.zon

	$HOME/.config/flat-wm/config.zon

The user configuration overrides compile-time configuration. You only need to
specify the values you want to change, rather than duplicating the entire
configuration.

The configuration is plain ZON. *flat-config* edits it in a terminal and keeps
its comments.

flat-wm reloads the user configuration on *SIGUSR1*, the same as the
*reload_config* action.

# EXAMPLES

Start flat-wm with flat, inside TTY, Wayland or X:
```
flat -c flat-wm
```

Restart flat-wm within the current session:
```
pkill -x flat-wm
nohup flat-wm >/dev/null &
```

Start flat-wm reading status from stdin (need user configuration):
```
flat -c 'while :; do date; sleep 1; done | flat-wm'
```

# SEE ALSO

_flat_(1), _kwim(1)_, _kwim(5)_

kwim:
```
https://github.com/kewuaa/kwim
```

Useful software:
```
https://codeberg.org/river/wiki/src/branch/main/pages/useful-software.md
```

# BUGS

https://github.com/kewuaa/kwm (upstream kwm)
