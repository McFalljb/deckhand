package core

import "core:sync"

// Pseudo-terminal interface. Each platform implements these procs in its own
// file: pty_posix.odin (macOS, Linux via forkpty). A Windows ConPTY version
// would implement the same procs in pty_windows.odin.
//
//   pty_spawn(argv, cwd, env, cols, rows) -> (Pty, ok)  start a child on a new pty
//   pty_wait_readable(&p, ms) -> bool    block until readable (reader thread)
//   pty_read(&p, buf) -> n                non-blocking; 0 = nothing now, -1 = closed
//   pty_write(&p, data)                   queues and writes what the pty accepts
//   pty_resize(&p, cols, rows, w_px, h_px)
//   pty_close(&p)                         hang up the child and release the pty
//   pty_reap()                            collect exited children (call each frame)
//   pty_foreground_busy(&p) -> bool       a program other than the child itself is in
//                                         the foreground (e.g. a shell running a command)
//   pty_foreground_pgrp(&p) -> i32        the foreground process group (0 = unknown)
//   pty_open(&p) -> bool                  a pty to read and write (ours, or the holder's)
//
// A held pty (held != 0) is a terminal in the session holder: its procs go over the holder
// wire (holder_client.odin), its output comes in through holder_pull, not a reader thread.

pty_open :: proc(p: ^Pty) -> bool {return p.fd >= 0 || p.held != 0}

// The fork lock. pty_spawn holds it exclusively from making its pipe until
// the pipe and the new master are close-on-exec; every other place that
// forks or spawns (from any thread) holds it shared around the fork, so no
// child is born holding a descriptor in that window. (POSIX_SPAWN_CLOEXEC_DEFAULT
// is macOS only.)
//
// Children are started with posix_spawn, never a plain fork (#78): in a process that loads CEF
// (the window, which runs the core in process in the fallback), a fork child runs the atfork
// handlers, and one that hangs there never execs and keeps our flocks (core.lock, instance.lock)
// after we quit. pty_spawn's forkpty is the exception: the shell needs the pty as its controlling
// terminal, which posix_spawn can't set up, and it runs in the window only in that fallback (the
// background core and the session holder load no CEF).
fork_lock: sync.RW_Mutex

Pty :: struct {
	fd:      i32, // master side (posix); -1 for a held pty
	held:    u32, // the session holder's terminal id (holder_client.odin); 0 = our own PTY
	pid:     i32,
	exited:  bool,
	pending: [dynamic]u8, // bytes the pty did not accept yet
}
