package zstd

// zstd's streaming decoder (the vendored single-file decoder, vendor/zstd/zstddeclib.c, zstd 1.5.7:
// vendor/zstd/VERSION), compiled into build/zstd/libzstddec.a by scripts/build-zstd.sh. Only what the
// core uses: the core reads the start of Codex's compressed rollouts with it
// (src/core/codex_disk.odin). A pure package: no state, no allocation of its own (the decoder's
// context is malloc'd by zstd and freed with dctx_free).

foreign import lib "../../build/zstd/libzstddec.a"

DCtx :: struct {}

In_Buffer :: struct {
	src:  rawptr,
	size: uint,
	pos:  uint,
}

Out_Buffer :: struct {
	dst:  rawptr,
	size: uint,
	pos:  uint,
}

// ZSTD_dParameter (zstd.h): the largest window a frame may ask for, as a power of two; a frame
// asking for more fails with an error instead of allocating it
D_WINDOW_LOG_MAX :: 100

@(default_calling_convention = "c")
foreign lib {
	@(link_name = "ZSTD_createDCtx")
	dctx_create :: proc() -> ^DCtx ---
	@(link_name = "ZSTD_freeDCtx")
	dctx_free :: proc(d: ^DCtx) -> uint ---
	@(link_name = "ZSTD_DCtx_setParameter")
	dctx_set_parameter :: proc(d: ^DCtx, param: i32, value: i32) -> uint ---
	// decodes from input into output, advancing both pos; an error is a code ZSTD_isError knows
	@(link_name = "ZSTD_decompressStream")
	decompress_stream :: proc(d: ^DCtx, output: ^Out_Buffer, input: ^In_Buffer) -> uint ---
	@(link_name = "ZSTD_isError")
	is_error :: proc(code: uint) -> u32 ---
	@(link_name = "ZSTD_versionNumber")
	version_number :: proc() -> u32 ---
}
