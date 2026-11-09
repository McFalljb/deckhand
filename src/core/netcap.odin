package core

// Another machine's pages and this Mac's network (docs/plans/background-core.md §8.3 P7, §10.4
// M6-D). A remote session's browser tabs run in this Mac's CEF, so a page there could reach what
// only this Mac reaches: its loopback services, its LAN, a cloud's metadata address. It may reach
// none of them, except a loopback port the user forwarded from that machine (machine_forward.odin).
//
// The classifier: a host is Public, Loopback (127/8, ::1, localhost, *.localhost), Private (the
// rest of this Mac's networks: 0/8, RFC 1918, link-local, CGNAT, multicast and reserved; IPv6
// unspecified, ULA, link- and site-local, multicast; IPv4 inside IPv6, mapped, compatible, NAT64
// and 6to4, by the IPv4 inside; *.local), a Name (resolved before it is allowed: netcap_lookup), or
// Bad (refused: empty, a zone, numeric but no address). IPv4 is read as browsers and inet_aton read
// it: one to four parts, each decimal, octal (a leading 0) or hex (0x); Chromium hands over its
// canonical form, and these forms are read anyway. CEF gives no resolved address before a request,
// so a Name's lookup is our own: a name that resolves differently for Chromium a moment later (DNS
// rebinding) is the stated residual (R10). Pure, and allocation-free: CEF's IO thread calls it.

import "core:strings"
import "core:sys/posix"

Net_Class :: enum u8 {
	Public,
	Loopback,
	Private,
	Name,
	Bad,
}

// A URL's parts (slices of it): its scheme as written, its host (an IPv6 one with its brackets),
// its port (the scheme's own when none is given), and what follows the host and port.
Net_Url :: struct {
	scheme, host: string,
	port:         int,
	rest:         string,
}

// The hosts and their class.
netcap_host_class :: proc(host: string) -> Net_Class {
	h := host
	if len(h) >= 2 && h[0] == '[' && h[len(h) - 1] == ']' do h = h[1:len(h) - 1]
	if strings.index_byte(h, ':') >= 0 {
		a, ok := netcap_ip6_parse(h)
		if !ok do return .Bad
		return netcap_ip6_class(a)
	}
	for len(h) > 0 && h[len(h) - 1] == '.' do h = h[:len(h) - 1]
	if h == "" do return .Bad
	if a, ok, numeric := netcap_ip4_parse(h); numeric {
		if !ok do return .Bad
		return netcap_ip4_class(a)
	}
	if strings.equal_fold(h, "localhost") || fold_suffix(h, ".localhost") do return .Loopback
	if fold_suffix(h, ".local") do return .Private
	return .Name
}

// Whether a page of another machine may reach scheme://host:port. forwarded: this Mac's loopback
// ports the user forwarded from that machine. lookup_private: a Name resolved to a loopback or
// private address, or did not resolve (netcap_lookup).
netcap_allowed :: proc(scheme, host: string, port: int, forwarded: []u16, lookup_private: bool) -> bool {
	switch {
	case strings.equal_fold(scheme, "http"), strings.equal_fold(scheme, "https"), strings.equal_fold(scheme, "ws"), strings.equal_fold(scheme, "wss"):
	case:
		return false
	}
	switch netcap_host_class(host) {
	case .Public:
		return true
	case .Name:
		return !lookup_private
	case .Loopback:
		// a forward is the user's: localhost, 127.0.0.1 and ::1 on its port, nothing else
		if !netcap_forward_host(host) do return false
		for p in forwarded do if int(p) == port do return true
		return false
	case .Private, .Bad:
	}
	return false
}

// The hosts a forwarded port answers on: ssh -L binds 127.0.0.1 (machine_forward_argv), and
// localhost reaches it (its ::1 was free when the forward was made).
netcap_forward_host :: proc(host: string) -> bool {
	h := strings.trim_right(host, ".")
	return strings.equal_fold(h, "localhost") || h == "127.0.0.1"
}

// Whether host (a Name) resolves to anything but public addresses (or nothing). Blocks: CEF's IO
// thread runs it off its own (cef_polish.inc). host: NUL-terminated.
netcap_lookup :: proc(host: cstring) -> (private: bool) {
	hints := posix.addrinfo {
		ai_socktype = .STREAM,
	}
	res: ^posix.addrinfo
	if posix.getaddrinfo(host, nil, &hints, &res) != .NONE || res == nil do return true
	defer posix.freeaddrinfo(res)
	n := 0
	for ai := res; ai != nil; ai = ai.ai_next {
		if ai.ai_addr == nil do continue
		#partial switch ai.ai_family {
		case .INET:
			sin := (^posix.sockaddr_in)(ai.ai_addr)
			a := transmute([4]u8)sin.sin_addr.s_addr
			if netcap_ip4_class(a) != .Public do return true
			n += 1
		case .INET6:
			sin6 := (^posix.sockaddr_in6)(ai.ai_addr)
			a := sin6.sin6_addr.s6_addr
			if netcap_ip6_class(a) != .Public do return true
			n += 1
		case:
			return true
		}
	}
	return n == 0
}

// scheme://[user@]host[:port][/?#…]: its parts. False: no authority (file:, data:, javascript:…),
// or a port that is not one.
netcap_url_parts :: proc(url: string) -> (u: Net_Url, ok: bool) {
	i := strings.index(url, "://")
	if i <= 0 do return {}, false
	u.scheme = url[:i]
	for c in u.scheme do if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.') do return {}, false
	rest := url[i + 3:]
	end := len(rest)
	if k := strings.index_any(rest, "/?#\\"); k >= 0 do end = k
	auth := rest[:end]
	u.rest = rest[end:]
	if at := strings.last_index_byte(auth, '@'); at >= 0 do auth = auth[at + 1:]
	host, port := auth, ""
	if strings.has_prefix(auth, "[") {
		close := strings.index_byte(auth, ']')
		if close < 0 do return {}, false
		host = auth[:close + 1]
		after := auth[close + 1:]
		if after != "" {
			if after[0] != ':' do return {}, false
			port = after[1:]
		}
	} else if c := strings.last_index_byte(auth, ':'); c >= 0 {
		host, port = auth[:c], auth[c + 1:]
	}
	if host == "" do return {}, false
	u.host = host
	if port == "" {
		switch {
		case strings.equal_fold(u.scheme, "https"), strings.equal_fold(u.scheme, "wss"): u.port = 443
		case strings.equal_fold(u.scheme, "http"), strings.equal_fold(u.scheme, "ws"):   u.port = 80
		}
		return u, true
	}
	n := 0
	for c in port {
		if c < '0' || c > '9' do return {}, false
		n = n * 10 + int(c - '0')
		if n > 65535 do return {}, false
	}
	u.port = n
	return u, true
}

netcap_ip4_class :: proc(a: [4]u8) -> Net_Class {
	switch {
	case a[0] == 127:                                 return .Loopback
	case a[0] == 0, a[0] == 10:                       return .Private
	case a[0] == 172 && a[1] & 0xf0 == 16:            return .Private
	case a[0] == 192 && a[1] == 168:                  return .Private
	case a[0] == 169 && a[1] == 254:                  return .Private // link-local
	case a[0] == 100 && a[1] & 0xc0 == 64:            return .Private // CGNAT, 100.64/10
	case a[0] >= 224:                                 return .Private // multicast, reserved, broadcast
	}
	return .Public
}

netcap_ip6_class :: proc(a: [16]u8) -> Net_Class {
	zero12 := true
	for i in 0 ..< 12 do if a[i] != 0 do zero12 = false
	v4 :: proc(a: [16]u8, at: int) -> [4]u8 {return {a[at], a[at + 1], a[at + 2], a[at + 3]}}
	switch {
	case zero12:
		if a[12] == 0 && a[13] == 0 && a[14] == 0 && a[15] <= 1 do return a[15] == 1 ? .Loopback : .Private // ::1, ::
		return netcap_ip4_class(v4(a, 12)) // IPv4-compatible
	case a[10] == 0xff && a[11] == 0xff && zero_to(a, 10):
		return netcap_ip4_class(v4(a, 12)) // mapped
	case a[0] == 0x00 && a[1] == 0x64 && a[2] == 0xff && a[3] == 0x9b:
		if a[4] == 0 && a[5] == 1 do return .Private // 64:ff9b:1::/48, local-use NAT64
		return netcap_ip4_class(v4(a, 12)) // NAT64
	case a[0] == 0x20 && a[1] == 0x02:
		return netcap_ip4_class(v4(a, 2)) // 6to4
	case a[0] == 0xfe && a[1] & 0xc0 == 0x80, a[0] == 0xfe && a[1] & 0xc0 == 0xc0: // link-local, site-local
		return .Private
	case a[0] & 0xfe == 0xfc, a[0] == 0xff: // ULA, multicast
		return .Private
	}
	return .Public

	zero_to :: proc(a: [16]u8, n: int) -> bool {
		for i in 0 ..< n do if a[i] != 0 do return false
		return true
	}
}

// An IPv4 address in any form a browser reads. numeric: the host is one (its last part is a
// number), so it is an address or nothing (ok false) and never a name.
netcap_ip4_parse :: proc(host: string) -> (a: [4]u8, ok: bool, numeric: bool) {
	h := host
	if len(h) > 1 && h[len(h) - 1] == '.' do h = h[:len(h) - 1]
	parts: [5]string
	n := 0
	rest := h
	for {
		k := strings.index_byte(rest, '.')
		part := k < 0 ? rest : rest[:k]
		if n == len(parts) do return {}, false, last_numeric(h)
		parts[n] = part
		n += 1
		if k < 0 do break
		rest = rest[k + 1:]
	}
	if !part_numeric(parts[n - 1]) do return {}, false, false
	numeric = true
	if n > 4 do return {}, false, true
	vals: [4]u64
	for i in 0 ..< n {
		v, vok := part_value(parts[i])
		if !vok do return {}, false, true
		vals[i] = v
	}
	for i in 0 ..< n - 1 do if vals[i] > 255 do return {}, false, true
	if vals[n - 1] >= u64(1) << uint(8 * (5 - n)) do return {}, false, true
	ip := vals[n - 1]
	for i in 0 ..< n - 1 do ip += vals[i] << uint(8 * (3 - i))
	return {u8(ip >> 24), u8(ip >> 16), u8(ip >> 8), u8(ip)}, true, true

	last_numeric :: proc(h: string) -> bool {
		k := strings.last_index_byte(h, '.')
		return part_numeric(k < 0 ? h : h[k + 1:])
	}
	part_numeric :: proc(p: string) -> bool {
		if p == "" do return false
		if len(p) >= 2 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') {
			for c in p[2:] do if !hex_digit(c) do return false
			return true
		}
		for c in p do if c < '0' || c > '9' do return false
		return true
	}
	part_value :: proc(p: string) -> (v: u64, ok: bool) {
		if p == "" do return 0, false
		base: u64 = 10
		digits := p
		if len(p) >= 2 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') {
			base, digits = 16, p[2:]
		} else if len(p) > 1 && p[0] == '0' {
			base, digits = 8, p[1:]
		}
		for c in digits {
			d: u64
			switch {
			case c >= '0' && c <= '9': d = u64(c - '0')
			case c >= 'a' && c <= 'f': d = u64(c - 'a' + 10)
			case c >= 'A' && c <= 'F': d = u64(c - 'A' + 10)
			case: return 0, false
			}
			if d >= base do return 0, false
			v = v * base + d
			if v > 0xffff_ffff do return 0, false
		}
		return v, true
	}
}

// An IPv6 address (no brackets, no zone): groups of hex, one "::", an IPv4 dotted quad last.
netcap_ip6_parse :: proc(s: string) -> (a: [16]u8, ok: bool) {
	if s == "" || strings.index_byte(s, '%') >= 0 do return {}, false
	head: [8]u16
	tail: [8]u16
	nh, nt := 0, 0
	gap := false
	rest := s
	if strings.has_prefix(rest, "::") {
		gap = true
		rest = rest[2:]
	}
	v4: [4]u8
	has_v4 := false
	for rest != "" {
		k := strings.index_byte(rest, ':')
		part := k < 0 ? rest : rest[:k]
		if part == "" do return {}, false
		if strings.index_byte(part, '.') >= 0 {
			if k >= 0 do return {}, false // the dotted quad comes last
			x, xok, _ := netcap_ip4_parse(part)
			if !xok || strings.count(part, ".") != 3 do return {}, false
			for c in part do if !(c >= '0' && c <= '9' || c == '.') do return {}, false
			v4, has_v4 = x, true
			rest = ""
			break
		}
		if len(part) > 4 do return {}, false
		g: u16
		for c in part {
			if !hex_digit(c) do return {}, false
			g = g << 4 | u16(hex_value(c))
		}
		if gap {
			if nt == 8 do return {}, false
			tail[nt] = g
			nt += 1
		} else {
			if nh == 8 do return {}, false
			head[nh] = g
			nh += 1
		}
		if k < 0 {
			rest = ""
			break
		}
		rest = rest[k + 1:]
		if strings.has_prefix(rest, ":") {
			if gap do return {}, false // a second "::"
			gap = true
			rest = rest[1:]
		} else if rest == "" do return {}, false // a trailing single ":"
	}
	groups := nh + nt + (has_v4 ? 2 : 0)
	if groups > 8 || (!gap && groups != 8) || (gap && groups == 8) do return {}, false
	words: [8]u16
	for i in 0 ..< nh do words[i] = head[i]
	at := 8 - nt - (has_v4 ? 2 : 0)
	for i in 0 ..< nt do words[at + i] = tail[i]
	for i in 0 ..< 8 {
		a[2 * i] = u8(words[i] >> 8)
		a[2 * i + 1] = u8(words[i])
	}
	if has_v4 do for i in 0 ..< 4 do a[12 + i] = v4[i]
	return a, true
}

@(private = "file")
hex_digit :: proc(c: rune) -> bool {return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'}

@(private = "file")
hex_value :: proc(c: rune) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a' + 10)
	}
	return int(c - 'A' + 10)
}

@(private = "file")
fold_suffix :: proc(s, suffix: string) -> bool {
	return len(s) >= len(suffix) && strings.equal_fold(s[len(s) - len(suffix):], suffix)
}
