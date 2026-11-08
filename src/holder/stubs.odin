package holder

// Placeholders the PR B workers replace (detach.odin).
detach_main :: proc(args: []string) -> int {return 2}

// The launcher's ready socket (§6, W2's detach.odin): connect, send our pid, receive the
// environment ("K=V" entries) to apply before serving. ok=false: the handshake failed.
ready_handshake :: proc(path: string) -> (env: []string, ok: bool) {return nil, false}
