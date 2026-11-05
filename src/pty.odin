package main

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

Pty :: struct {
	fd:      i32, // master side (posix)
	pid:     i32,
	exited:  bool,
	pending: [dynamic]u8, // bytes the pty did not accept yet
}
