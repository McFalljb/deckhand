package core

// Another machine's pages and this Mac's network (netcap.odin; §8.3 P7, §10.4 M6-D): the address
// classifier's table. Pure: no lookup runs.

import "core:strings"
import "core:testing"

@(test)
netcap_classifier_table :: proc(t: ^testing.T) {
	Row :: struct {
		host: string,
		want: Net_Class,
	}
	rows := []Row {
		// IPv4 literals
		{"8.8.8.8", .Public},
		{"1.1.1.1", .Public},
		{"127.0.0.1", .Loopback},
		{"127.9.8.7", .Loopback},
		{"0.0.0.0", .Private}, // reaches this Mac on macOS
		{"10.1.2.3", .Private},
		{"172.16.0.1", .Private},
		{"172.31.255.255", .Private},
		{"172.32.0.1", .Public},
		{"192.168.1.10", .Private},
		{"169.254.169.254", .Private}, // link-local (a cloud's metadata)
		{"100.64.0.1", .Private}, // CGNAT
		{"100.127.255.255", .Private},
		{"100.128.0.1", .Public},
		{"224.0.0.251", .Private}, // multicast
		{"255.255.255.255", .Private},
		// the other IPv4 forms (inet_aton, WHATWG): decimal, octal, hex, fewer parts
		{"2130706433", .Loopback}, // 127.0.0.1
		{"0x7f000001", .Loopback},
		{"0x7F.1", .Loopback},
		{"017700000001", .Loopback}, // octal
		{"0177.0.0.1", .Loopback},
		{"127.1", .Loopback},
		{"127.0.1", .Loopback},
		{"3232235777", .Private}, // 192.168.1.1
		{"0xc0.0xa8.1.1", .Private},
		{"0300.0250.1.1", .Private},
		{"167772161", .Private}, // 10.0.0.1
		{"134744072", .Public}, // 8.8.8.8
		{"127.0.0.1.", .Loopback}, // a trailing dot
		// numeric but not an address: refused, never resolved
		{"4294967296", .Bad},
		{"256.1.1.1", .Bad},
		{"1.2.3.4.5", .Bad},
		{"0x", .Private}, // WHATWG: "0x" is 0, so 0.0.0.0
		{"09.1.1.1", .Bad}, // not octal
		// IPv6 literals (with or without brackets)
		{"[::1]", .Loopback},
		{"::1", .Loopback},
		{"[0:0:0:0:0:0:0:1]", .Loopback},
		{"[::]", .Private},
		{"[fe80::1]", .Private},
		{"[febf::1]", .Private},
		{"[fec0::1]", .Private}, // site-local
		{"[fc00::1]", .Private}, // ULA
		{"[fd12:3456::1]", .Private},
		{"[ff02::1]", .Private}, // multicast
		{"[2606:4700::1111]", .Public},
		{"[::ffff:127.0.0.1]", .Loopback}, // mapped
		{"[::ffff:7f00:1]", .Loopback},
		{"[::ffff:192.168.0.1]", .Private},
		{"[::ffff:8.8.8.8]", .Public},
		{"[::127.0.0.1]", .Loopback}, // IPv4-compatible
		{"[64:ff9b::10.0.0.1]", .Private}, // NAT64
		{"[64:ff9b::8.8.8.8]", .Public},
		{"[2002:c0a8:101::1]", .Private}, // 6to4 of 192.168.1.1
		{"[fe80::1%25en0]", .Bad}, // a zone
		{"[1::2::3]", .Bad},
		{"[12345::]", .Bad},
		// names
		{"localhost", .Loopback},
		{"LOCALHOST", .Loopback},
		{"localhost.", .Loopback},
		{"app.localhost", .Loopback},
		{"printer.local", .Private},
		{"Printer.LOCAL.", .Private},
		{"example.com", .Name},
		{"localhost.example.com", .Name},
		{"", .Bad},
	}
	for r in rows {
		got := netcap_host_class(r.host)
		testing.expectf(t, got == r.want, "%q: %v, want %v", r.host, got, r.want)
	}
}

@(test)
netcap_url_and_verdicts :: proc(t: ^testing.T) {
	Row :: struct {
		url:          string,
		scheme, host: string,
		port:         int,
		ok:           bool,
	}
	rows := []Row {
		{"http://localhost:3000/a?b", "http", "localhost", 3000, true},
		{"https://example.com/", "https", "example.com", 443, true},
		{"http://example.com", "http", "example.com", 80, true},
		{"HTTP://User:pw@Example.com:8080/x", "http", "Example.com", 8080, true},
		{"http://[::1]:8080/", "http", "[::1]", 8080, true},
		{"http://[::1]/", "http", "[::1]", 80, true},
		{"ws://127.0.0.1:9/", "ws", "127.0.0.1", 9, true},
		{"http://a@b@127.0.0.1/", "http", "127.0.0.1", 80, true}, // the last @ ends the user part
		{"http://h:99999/", "", "", 0, false},
		{"http://h:x/", "", "", 0, false},
		{"file:///etc/passwd", "file", "", 0, false},
		{"javascript:alert(1)", "", "", 0, false},
		{"data:text/html,hi", "", "", 0, false},
	}
	for r in rows {
		u, ok := netcap_url_parts(r.url)
		testing.expectf(t, ok == r.ok, "%q: ok %v", r.url, ok)
		if !r.ok do continue
		testing.expectf(t, strings.equal_fold(u.scheme, r.scheme) && u.host == r.host && u.port == r.port, "%q: %v", r.url, u)
	}
	// what a page of another machine may reach: public yes; this Mac's loopback only on a
	// forwarded port; the rest of this Mac's networks never (a name: after the lookup)
	fw := []u16{5173}
	testing.expect(t, netcap_allowed("http", "example.com", 80, fw, lookup_private = false))
	testing.expect(t, !netcap_allowed("http", "example.com", 80, fw, lookup_private = true))
	testing.expect(t, netcap_allowed("https", "8.8.8.8", 443, fw, false))
	testing.expect(t, !netcap_allowed("http", "127.0.0.1", 3000, fw, false))
	testing.expect(t, netcap_allowed("http", "127.0.0.1", 5173, fw, false))
	testing.expect(t, netcap_allowed("http", "localhost", 5173, fw, false))
	testing.expect(t, !netcap_allowed("ws", "[::1]", 5173, fw, false), "a forward binds 127.0.0.1 only")
	testing.expect(t, !netcap_allowed("http", "app.localhost", 5173, fw, false), "only localhost itself is forwarded")
	testing.expect(t, !netcap_allowed("http", "0x7f000001", 3000, fw, false))
	testing.expect(t, !netcap_allowed("http", "192.168.1.1", 5173, fw, false), "a forward is loopback's only")
	testing.expect(t, !netcap_allowed("http", "printer.local", 80, fw, false))
	testing.expect(t, !netcap_allowed("file", "", 0, fw, false))
	testing.expect(t, !netcap_allowed("ftp", "example.com", 21, fw, false))
	testing.expect(t, !netcap_allowed("http", "", 80, fw, false))
}
