package core

// fs_copy from outside every project (fs_copy_outside_source): only the user at this window (a
// Finder drop onto the Files tree) may copy IN from a folder that is no project; every other
// caller class keeps "only inside a project folder". The target's rules, links, .git, credentials
// and the caps are fs_copy's own, unchanged.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
osetup :: proc(tag: string) -> (proj, outside: string) {
	state = State{}
	base := fmt.tprintf("%s/dho-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/proj", base))
	os.make_directory_all(fmt.tprintf("%s/outside", base))
	base = fs_real(base, context.allocator)
	proj = fmt.aprintf("%s/proj", base)
	outside = fmt.aprintf("%s/outside", base)
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(proj), label = "proj"})
	return
}

@(private = "file")
owrite :: proc(path: string, text := "x") {
	os.make_directory_all(tdir(path))
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
oread :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<missing>"
}

@(private = "file")
ocopy :: proc(from, to: string, caller: Caller, unique := false) -> (plan: Fs_Copy_Plan, err: string) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	plan, err = fs_copy_plan(from, to, unique, caller, virtual.arena_allocator(&arena))
	if err != "" do return
	_, failed, rerr := fs_copy_run(plan)
	if rerr != "" do err = fmt.tprintf("%s: %s", failed, rerr)
	plan.to = strings.clone(plan.to, context.temp_allocator)
	skipped := make([]Fs_Copy_Skip, len(plan.skipped), context.temp_allocator)
	for s, i in plan.skipped do skipped[i] = {strings.clone(s.rel, context.temp_allocator), strings.clone(s.why, context.temp_allocator)}
	plan.skipped = skipped
	plan.items = nil
	return
}

@(test)
fs_copy_outside_source_per_caller :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, outside := osetup("callers")
	defer {os.remove_all(tdir(proj)); state = State{}}
	owrite(fmt.tprintf("%s/a.txt", outside), "from finder")
	owrite(fmt.tprintf("%s/dir/in.txt", outside), "in")
	// the user at this window: a file and a folder copied in
	_, err := ocopy(fmt.tprintf("%s/a.txt", outside), fmt.tprintf("%s/a.txt", proj), Caller{kind = .UI})
	testing.expect_value(t, err, "")
	testing.expect_value(t, oread(fmt.tprintf("%s/a.txt", proj)), "from finder")
	_, err = ocopy(fmt.tprintf("%s/dir", outside), fmt.tprintf("%s/dir", proj), Caller{kind = .UI})
	testing.expect_value(t, err, "")
	testing.expect_value(t, oread(fmt.tprintf("%s/dir/in.txt", proj)), "in")
	// a name taken: unique ("a copy.txt"), never over it
	plan, err2 := ocopy(fmt.tprintf("%s/a.txt", outside), fmt.tprintf("%s/a.txt", proj), Caller{kind = .UI}, unique = true)
	testing.expect_value(t, err2, "")
	testing.expect_value(t, plan.to, fmt.tprintf("%s/a copy.txt", proj))
	// every other caller class: only inside a project folder, nothing written
	others := []Caller{{kind = .Control}, {kind = .Script}, {kind = .Panel}, {kind = .Internal}, {kind = .UI, web = true}, {kind = .UI, hub = true}}
	for c in others {
		_, e := ocopy(fmt.tprintf("%s/a.txt", outside), fmt.tprintf("%s/b.txt", proj), c)
		testing.expectf(t, e == "only inside a project folder", "%v: %s", c, e)
		testing.expectf(t, !os.exists(fmt.tprintf("%s/b.txt", proj)), "%v: nothing written", c)
	}
	// the target's rules are unchanged: never outside a project, never into .git, never a project folder
	_, e := ocopy(fmt.tprintf("%s/a.txt", outside), fmt.tprintf("%s/a2.txt", outside), Caller{kind = .UI})
	testing.expect_value(t, e, "only inside a project folder")
	os.make_directory_all(fmt.tprintf("%s/.git", proj))
	_, e = ocopy(fmt.tprintf("%s/a.txt", outside), fmt.tprintf("%s/.git/a.txt", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "not inside .git")
	_, e = ocopy(fmt.tprintf("%s/dir", outside), proj, Caller{kind = .UI})
	testing.expect_value(t, e, "not on a project folder itself")
	// a relative source (to the session's folder) is never read as an outside path
	_, e = ocopy("a.txt", fmt.tprintf("%s/r.txt", proj), Caller{kind = .UI})
	testing.expect(t, e != "" && !os.exists(fmt.tprintf("%s/r.txt", proj)), e)
}

@(test)
fs_copy_outside_source_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, outside := osetup("rules")
	defer {os.remove_all(tdir(proj)); state = State{}}
	// a source inside a project keeps fs_check's refusals: its .git, the project's own folder
	os.make_directory_all(fmt.tprintf("%s/.git", proj))
	owrite(fmt.tprintf("%s/.git/config", proj), "[core]")
	_, e := ocopy(fmt.tprintf("%s/.git/config", proj), fmt.tprintf("%s/c.txt", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "not inside .git")
	_, e = ocopy(proj, fmt.tprintf("%s/p2", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "not on a project folder itself")
	// an outside source in a .git folder (any case) is refused too
	owrite(fmt.tprintf("%s/repo/.GIT/HEAD", outside), "ref")
	_, e = ocopy(fmt.tprintf("%s/repo/.GIT/HEAD", outside), fmt.tprintf("%s/h.txt", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "not inside .git")
	_, e = ocopy(fmt.tprintf("%s/repo/.GIT", outside), fmt.tprintf("%s/g", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "not inside .git")
	// an outside folder's own .git is left out (fs_copy's rule)
	owrite(fmt.tprintf("%s/repo/f.txt", outside), "f")
	plan, e2 := ocopy(fmt.tprintf("%s/repo", outside), fmt.tprintf("%s/repo", proj), Caller{kind = .UI})
	testing.expect_value(t, e2, "")
	testing.expect(t, os.exists(fmt.tprintf("%s/repo/f.txt", proj)) && !os.exists(fmt.tprintf("%s/repo/.GIT", proj)), "copied without .GIT")
	testing.expect(t, len(plan.skipped) == 1 && strings.contains(plan.skipped[0].why, "git"), "said")
	// a link is copied as a link (never followed), also as the source itself
	owrite(fmt.tprintf("%s/secret.txt", outside), "secret")
	posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/secret.txt", outside), context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/ln", outside), context.temp_allocator))
	_, e = ocopy(fmt.tprintf("%s/ln", outside), fmt.tprintf("%s/ln", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "")
	st: posix.stat_t
	testing.expect(t, posix.lstat(strings.clone_to_cstring(fmt.tprintf("%s/ln", proj), context.temp_allocator), &st) == .OK && posix.S_ISLNK(st.st_mode), "a link")
	// never through a project: a link in it that leads out is no way to an outside source
	posix.symlink(strings.clone_to_cstring(outside, context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/escape", proj), context.temp_allocator))
	_, e = ocopy(fmt.tprintf("%s/escape/secret.txt", proj), fmt.tprintf("%s/s.txt", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "only inside a project folder")
	// into itself: an outside folder holding the project is never copied into it
	_, e = ocopy(tdir(proj), fmt.tprintf("%s/up", proj), Caller{kind = .UI})
	testing.expect_value(t, e, FS_COPY_INTO_ITSELF)
	// a credential at the top: refused; inside a folder: left out and said
	owrite(fmt.tprintf("%s/cfg/.credentials.json", outside), "{}")
	owrite(fmt.tprintf("%s/cfg/notes.txt", outside), "n")
	_, e = ocopy(fmt.tprintf("%s/cfg/.credentials.json", outside), fmt.tprintf("%s/c.json", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "it is a credential: not copied")
	plan, e2 = ocopy(fmt.tprintf("%s/cfg", outside), fmt.tprintf("%s/cfg", proj), Caller{kind = .UI})
	testing.expect_value(t, e2, "")
	testing.expect(t, !os.exists(fmt.tprintf("%s/cfg/.credentials.json", proj)), "the credential is not copied")
	// gone: said
	_, e = ocopy(fmt.tprintf("%s/nope", outside), fmt.tprintf("%s/nope", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "no such file or folder")
}

// Review (#169 round 2): a project's own folder spelled in another case (a volume that ignores
// case) is no outside source.
@(test)
fs_copy_outside_source_case_variant :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, outside := osetup("case")
	defer {os.remove_all(tdir(proj)); state = State{}}
	other := fmt.aprintf("%s/other", tdir(proj))
	os.make_directory_all(other)
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(other), label = "other"})
	owrite(fmt.tprintf("%s/f.txt", proj), "f")
	variant := fmt.tprintf("%s/PROJ", tdir(proj))
	if !os.exists(variant) do return // a volume that keeps case: no such spelling
	_, e := ocopy(variant, fmt.tprintf("%s/p", other), Caller{kind = .UI})
	testing.expect(t, e != "", "the project's folder by another case is refused")
	testing.expect(t, !os.exists(fmt.tprintf("%s/p", other)), "nothing copied")
	// (a file inside it by another case is an ordinary copy from the project: fs_check reads its folder's real path)
	_ = outside
}

// Review (#169 round 2): the user's own secrets from outside (keys, ~/.aws, ~/.netrc) are never
// copied in by a drop: one dropped alone is refused; inside a dropped folder, left out and said.
// A secret already inside a project copies as before (the user's own tree copy).
@(test)
fs_copy_outside_source_secrets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, outside := osetup("secrets")
	defer {os.remove_all(tdir(proj)); state = State{}}
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	home := fmt.tprintf("%s/home", outside)
	os.set_env("HOME", home)
	owrite(fmt.tprintf("%s/.aws/credentials", home), "[default]")
	owrite(fmt.tprintf("%s/.netrc", home), "machine x")
	owrite(fmt.tprintf("%s/id_ed25519", outside), "key")
	owrite(fmt.tprintf("%s/keys/server.pem", outside), "pem")
	owrite(fmt.tprintf("%s/keys/ok.txt", outside), "ok")
	for src in ([]string{fmt.tprintf("%s/.aws/credentials", home), fmt.tprintf("%s/.aws", home), fmt.tprintf("%s/.netrc", home), fmt.tprintf("%s/id_ed25519", outside)}) {
		_, e := ocopy(src, fmt.tprintf("%s/s", proj), Caller{kind = .UI})
		testing.expectf(t, e == FS_COPY_SECRET, "%s: %s", src, e)
		testing.expect(t, !os.exists(fmt.tprintf("%s/s", proj)), "nothing copied")
	}
	plan, e := ocopy(fmt.tprintf("%s/keys", outside), fmt.tprintf("%s/keys", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "")
	testing.expect_value(t, oread(fmt.tprintf("%s/keys/ok.txt", proj)), "ok")
	testing.expect(t, !os.exists(fmt.tprintf("%s/keys/server.pem", proj)), "the key is left out")
	testing.expect(t, len(plan.skipped) == 1 && plan.skipped[0].rel == "server.pem" && plan.skipped[0].why == FS_COPY_SECRET, "said")
	// a home folder dropped whole: .aws and .netrc left out
	plan, e = ocopy(home, fmt.tprintf("%s/h", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "")
	testing.expect(t, !os.exists(fmt.tprintf("%s/h/.aws", proj)) && !os.exists(fmt.tprintf("%s/h/.netrc", proj)), "secrets left out")
	// inside a project: the user's own tree copy, as before
	owrite(fmt.tprintf("%s/in.pem", proj), "pem")
	_, e = ocopy(fmt.tprintf("%s/in.pem", proj), fmt.tprintf("%s/in2.pem", proj), Caller{kind = .UI})
	testing.expect_value(t, e, "")
}
