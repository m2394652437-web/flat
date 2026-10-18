FLAT(1)

; SPDX-FileCopyrightText: © 2020 The River Developers
; SPDX-FileCopyrightText: © 2026 CQZY (modified for Flat)
; SPDX-License-Identifier: CC-BY-SA-4.0

# NAME

flat - non-monolithic Wayland compositor, a fork of river

# SYNOPSIS

*flat* [_options_]

# DESCRIPTION

Flat is a fork of river 0.5.0, a non-monolithic Wayland compositor, it does not combine the compositor
and window manager into one program. Instead, users can choose any window
manager implementing the river-window-management-v1 protocol.

This means that flat is not useful without a compatible window manager. A list
of compatible window managers can be found on the river wiki:
https://codeberg.org/river/wiki/src/branch/main/pages/wm-list.md

# OPTIONS

*-h*
	Print a help message and exit.

*-version*
	Print the version number and exit.

*-c* _shell_command_
	Override the default search paths for an init executable: instead
	_shell_command_ will be run with _/bin/sh -c_. See the *CONFIGURATION*
	section for more details.

*-log-level* [*error*|*warning*|*info*|*debug*]
	Set the log level of flat. At the *error* log level, only errors
	are logged.  At the *debug* log level, everything is logged including
	verbose debug messages.

*-no-xwayland*
	Disable Xwayland at runtime even if flat has been built with support.

# KEYBINDINGS

The following keybindings are always active:

*Ctrl+Alt+F1* - *Ctrl+Alt+F12*
	Switch to VT 1-12

Window managers may add additional keybindings but cannot override these builtin
keybindings.

# CONFIGURATION

On startup flat will run an executable file at $XDG_CONFIG_HOME/flat/init if
such an executable exists. If $XDG_CONFIG_HOME is not set, ~/.config/flat/init
will be used instead.

The executable init file will be run as a process group leader after flat's
Wayland server is initialized but before entering the main loop. On exit,
flat will send SIGTERM to this process group.

Usually this executable is a shell script which starts the user's window manager
and any other long-running programs. For example, *kanshi*(1) could be started
to manage output configuration.

# AUTHORS

Flat is maintained by CQZY. It is based on river, which is maintained by
Isaac Freund <mail@isaacfreund.com> who is assisted by open source
contributors. For more information about river's development, see
<https://isaacfreund.com/software/river>.
