package main

// Markdown parser tests: CommonMark and GFM spec examples (vendored in
// tests/markdown/, sources and licence in tests/markdown/README.md), the
// parse time of a 1 MB file, and the parts the viewer relies on (task
// items, heading ids, fenced languages).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
Spec_Example :: struct {
	number:  int,
	section: string,
	md:      string,
	html:    string,
}

FENCE_32 :: "````````````````````````````````"

// Examples in the spec's own format ("→" stands for a tab).
@(private = "file")
spec_examples :: proc(text: string) -> [dynamic]Spec_Example {
	out := make([dynamic]Spec_Example, context.temp_allocator)
	lines := strings.split(text, "\n", context.temp_allocator)
	i := 0
	for i < len(lines) {
		l := lines[i]
		i += 1
		if !strings.has_prefix(l, FENCE_32 + " example") do continue
		head := strings.trim_space(l[len(FENCE_32 + " example"):])
		num_s, _, sec := strings.partition(head, " ")
		ex := Spec_Example{section = sec}
		for c in num_s do ex.number = ex.number * 10 + int(c - '0')
		md := strings.builder_make(context.temp_allocator)
		html := strings.builder_make(context.temp_allocator)
		cur := &md
		for i < len(lines) && lines[i] != FENCE_32 {
			if lines[i] == "." && cur == &md {
				cur = &html
			} else {
				strings.write_string(cur, lines[i])
				strings.write_byte(cur, '\n')
			}
			i += 1
		}
		i += 1
		ex.md, _ = strings.replace_all(strings.to_string(md), "→", "\t", context.temp_allocator)
		ex.html, _ = strings.replace_all(strings.to_string(html), "→", "\t", context.temp_allocator)
		append(&out, ex)
	}
	return out
}

@(private = "file")
run_examples :: proc(t: ^testing.T, text: string, report := true) -> (pass, total: int) {
	for ex in spec_examples(text) {
		doc := md_parse(ex.md)
		got := md_html(doc, context.temp_allocator)
		md_free(doc)
		total += 1
		if got == ex.html {
			pass += 1
		} else if report {
			testing.expectf(t, false, "example %d (%s)\n--- markdown\n%s--- want\n%s--- got\n%s", ex.number, ex.section, ex.md, ex.html, got)
		}
	}
	return
}

MD_COMMONMARK_EXAMPLES :: #load("../tests/markdown/commonmark-examples.txt", string)
MD_GFM_EXAMPLES :: #load("../tests/markdown/gfm-examples.txt", string)

@(test)
markdown_commonmark_spec :: proc(t: ^testing.T) {
	pass, total := run_examples(t, MD_COMMONMARK_EXAMPLES)
	testing.expectf(t, total >= 150, "only %d examples vendored", total)
	testing.expectf(t, pass == total, "%d of %d CommonMark examples pass", pass, total)
}

@(test)
markdown_gfm_spec :: proc(t: ^testing.T) {
	pass, total := run_examples(t, MD_GFM_EXAMPLES)
	testing.expectf(t, total >= 20, "only %d GFM examples vendored", total)
	testing.expectf(t, pass == total, "%d of %d GFM examples pass", pass, total)
}

// The whole spec (not vendored): PI_DESK_MD_SPEC=path/to/examples.txt
// (tests/markdown/README.md says how to make it) prints a pass count per
// section and the failing examples' numbers. Never fails.
@(test)
markdown_spec_report :: proc(t: ^testing.T) {
	path := os.get_env("PI_DESK_MD_SPEC", context.temp_allocator)
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		return
	}
	Sec :: struct {
		pass, total: int,
		failed:      [dynamic]int,
	}
	secs := make(map[string]Sec, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	all, ok := 0, 0
	for ex in spec_examples(string(data)) {
		doc := md_parse(ex.md)
		got := md_html(doc, context.temp_allocator)
		md_free(doc)
		if ex.section not_in secs {
			append(&order, ex.section)
			secs[ex.section] = Sec{failed = make([dynamic]int, context.temp_allocator)}
		}
		s := &secs[ex.section]
		s.total += 1
		all += 1
		if got == ex.html {
			s.pass += 1
			ok += 1
		} else do append(&s.failed, ex.number)
	}
	for name in order {
		s := secs[name]
		fmt.printfln("%-48s %3d/%3d %v", name, s.pass, s.total, s.failed[:])
	}
	fmt.printfln("total %d/%d", ok, all)
}

// A 1 MB document of every construct parses in under 50 ms.
@(test)
markdown_parse_1mb :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	chunk := "# Heading with *emphasis* and `code`\n\nA paragraph with **strong**, _emph_, a [link](http://example.com \"t\"), an ![image](a.png),\nan autolink <https://example.com/x>, www.example.org, ~~struck~~ text and a\nsecond line with an entity &amp; and an escape \\* here.\n\n- item one\n- item two with `code`\n  - nested [ref][r]\n- [x] a done task\n\n1. first\n2. second\n\n> a quote with *more* text\n> over two lines\n\n```go\nfunc main() {\n\tprintln(\"hi\")\n}\n```\n\n| a | b |\n|---|:-:|\n| 1 | **2** |\n| 3 | 4 |\n\n    indented code\n\n<div>html</div>\n\n---\n\n[r]: /reference \"Title\"\n\n"
	for strings.builder_len(sb) < 1 << 20 do strings.write_string(&sb, chunk)
	text := strings.to_string(sb)
	best := time.Duration(1 << 62)
	for _ in 0 ..< 3 {
		t0 := time.tick_now()
		doc := md_parse(text)
		d := time.tick_since(t0)
		best = min(best, d)
		testing.expect(t, len(doc.root.children) > 1000, "parsed")
		md_free(doc)
	}
	fmt.printfln("markdown: 1 MB parsed in %.1f ms (best of 3)", f64(best) / f64(time.Millisecond))
	testing.expectf(t, best < 50 * time.Millisecond, "1 MB took %v (limit 50 ms)", best)
}

@(test)
markdown_viewer_bits :: proc(t: ^testing.T) {
	doc := md_parse("# Hello, World!\n\n## Hello, World!\n\n- [ ] open\n- [x] done\n\n```mermaid\ngraph TD\n```\n\n```go\nx\n```\n")
	defer md_free(doc)
	c := doc.root.children
	testing.expect_value(t, c[0].anchor, "hello-world")
	testing.expect_value(t, c[1].anchor, "hello-world-1")
	testing.expect(t, doc.anchors["hello-world-1"] == c[1], "anchor map")
	testing.expect_value(t, c[2].children[0].task, u8(1))
	testing.expect_value(t, c[2].children[1].task, u8(2))
	testing.expect_value(t, md_plain_text(c[2].children[1].children[0].inl, context.temp_allocator), "done")
	testing.expect_value(t, c[3].info, "mermaid")
	testing.expect_value(t, c[3].line, 8)
	testing.expect_value(t, c[4].line, 12)
}

// Named references: the whole HTML5 table (2,125 names with the ';'), not a
// subset: letters from other scripts, multi-code-point values, the longest
// name, control characters; a name that is not in the table stays literal.
@(test)
markdown_entities_html5 :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"Afr", "\U0001D504"}, {"zopf", "\U0001D56B"}, {"bne", "=\u20E5"}, {"fjlig", "fj"},
		{"NewLine", "\n"}, {"Tab", "\t"}, {"ngE", "\u2267\u0338"}, {"Lsh", "\u21B0"},
		{"CounterClockwiseContourIntegral", "\u2233"}, {"amp", "&"}, {"quot", "\""}, {"nbsp", "\u00A0"},
	}
	for c in cases {
		got, n, ok := md_entity(strings.concatenate({c[0], ";x"}, context.temp_allocator), context.temp_allocator)
		testing.expectf(t, ok && got == c[1] && n == len(c[0]) + 1, "&%s; -> %q (ok %v, n %d), want %q", c[0], got, ok, n, c[1])
	}
	for name in ([]string{"madeup", "Afrx", "AFR", "amp_"}) {
		_, _, ok := md_entity(strings.concatenate({name, ";"}, context.temp_allocator), context.temp_allocator)
		testing.expectf(t, !ok, "&%s; is not an entity", name)
	}
	doc := md_parse("&Afr; &Bopf; &madeup;\n")
	defer md_free(doc)
	testing.expect_value(t, md_html(doc, context.temp_allocator), "<p>\U0001D504 \U0001D539 &amp;madeup;</p>\n")
}

// Random Markdown-ish text never panics (a panic would take the app down):
// 4000 inputs from the characters that start or end constructs.
@(test)
markdown_fuzz :: proc(t: ^testing.T) {
	ALPHABET := " \t\n\n\n>-*_+=#`~[]()!<>:/\\&;|\"'.1aWw@xh"
	seed := u64(0x9E3779B97F4A7C15)
	next :: proc(s: ^u64) -> u64 {
		s^ ~= s^ << 13
		s^ ~= s^ >> 7
		s^ ~= s^ << 17
		return s^
	}
	buf: [400]u8
	words := []string{"www.", "http://", "<!--", "-->", "```", "~~~", "| - |", "[x] ", "<div>", "</div>", "&amp;", "&#x41;", "    ", "1. ", "- ", "> ", "***", "<a href='", "[r]: /u", "é", "�"}
	for _ in 0 ..< 4000 {
		n := int(next(&seed) % u64(len(buf)))
		i := 0
		for i < n {
			if next(&seed) % 6 == 0 {
				w := words[next(&seed) % u64(len(words))]
				if i + len(w) > n do break
				copy(buf[i:], w)
				i += len(w)
			} else {
				buf[i] = ALPHABET[next(&seed) % u64(len(ALPHABET))]
				i += 1
			}
		}
		doc := md_parse(string(buf[:i]))
		_ = md_html(doc, context.temp_allocator)
		md_free(doc)
		free_all(context.temp_allocator)
	}
}

// Inputs that are slow or deep for naive parsers (cmark's pathological
// tests): each parses quickly and without running out of stack.
@(test)
markdown_pathological :: proc(t: ^testing.T) {
	rep :: proc(s: string, n: int) -> string {return strings.repeat(s, n, context.temp_allocator)}
	cat :: proc(parts: ..string) -> string {return strings.concatenate(parts, context.temp_allocator)}
	cases := []struct {
		name: string,
		text: string,
	} {
		{"nested block quotes", rep(">", 50_000)},
		{"nested lists", cat(rep("- ", 20_000), "x")},
		{"nested emphasis", cat(rep("*", 30_000), "a", rep("*", 30_000))},
		{"open brackets", cat(rep("[", 50_000), "a")},
		{"links in brackets", rep("[a](b) [", 20_000)},
		{"unclosed backticks", rep("`a``", 30_000)},
		{"emphasis openers", rep("*a ", 50_000)},
		{"underscores", rep("_a", 50_000)},
		{"nested links", cat(rep("[", 20_000), "a", rep("](b)", 20_000))},
		{"nested images", cat(rep("![", 20_000), "a", rep("](b)", 20_000))},
		{"table columns", cat("|", rep("a|", 5_000), "\n|", rep("-|", 5_000), "\n", rep("|b", 5_000), "\n")},
	}
	for c in cases {
		t0 := time.tick_now()
		doc := md_parse(c.text)
		_ = md_html(doc, context.temp_allocator)
		md_free(doc)
		d := time.tick_since(t0)
		testing.expectf(t, d < 2 * time.Second, "%s took %v", c.name, d)
		free_all(context.temp_allocator)
	}
}
