#!/bin/sh
set -eu
cd "$(dirname "$0")"
api="ZSTD_versionNumber ZSTD_compressBound ZSTD_isError ZSTD_createCCtx ZSTD_freeCCtx ZSTD_createDCtx ZSTD_freeDCtx ZSTD_createCDict ZSTD_freeCDict ZSTD_createDDict ZSTD_freeDDict ZSTD_compressCCtx ZSTD_decompressDCtx ZSTD_compress_usingCDict ZSTD_decompress_usingDDict ZDICT_trainFromBuffer ZDICT_isError"
defs="-DNDEBUG -DZSTD_STRIP_ERROR_STRINGS=1 -DZSTD_EXCLUDE_GREEDY_BLOCK_COMPRESSOR -DZSTD_EXCLUDE_BTLAZY2_BLOCK_COMPRESSOR -DZSTD_EXCLUDE_BTOPT_BLOCK_COMPRESSOR -DZSTD_EXCLUDE_BTULTRA_BLOCK_COMPRESSOR -DZSTDLIB_VISIBLE= -DZSTDERRORLIB_VISIBLE= -DZDICTLIB_VISIBLE= -DZSTDLIB_STATIC_API= -DZDICTLIB_STATIC_API="
flags="-std=c11 -O3 -fvisibility=hidden -ffunction-sections -fdata-sections -fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
roots=""
case "$(uname -s)-$(uname -m)" in
Linux-x86_64)
	for f in $api; do roots="$roots -u $f"; done
	clang $flags $defs -fPIC -c src/zstd.c -o "$tmp/full.o"
	ld -r --gc-sections $roots "$tmp/full.o" -o "$tmp/zstd.o"
	rm -f lib/libzstd_linux_amd64.a
	ar rcsD lib/libzstd_linux_amd64.a "$tmp/zstd.o"
	;;
Darwin-arm64)
	clang $flags $defs -arch arm64 -mmacosx-version-min=11.0 -c src/zstd.c -o "$tmp/zstd.o"
	rm -f lib/libzstd_darwin_arm64.a
	libtool -static -D -o lib/libzstd_darwin_arm64.a "$tmp/zstd.o"
	;;
*)
	echo "unsupported host $(uname -s)-$(uname -m)" >&2
	exit 1
	;;
esac
