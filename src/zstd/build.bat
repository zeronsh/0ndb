@echo off
setlocal
cd /d "%~dp0"
cl /nologo /c /O2 /Oi /GS- /Gy /Gw /Zl /std:c11 /DNDEBUG /DZSTD_STRIP_ERROR_STRINGS=1 /DZSTD_EXCLUDE_GREEDY_BLOCK_COMPRESSOR /DZSTD_EXCLUDE_BTLAZY2_BLOCK_COMPRESSOR /DZSTD_EXCLUDE_BTOPT_BLOCK_COMPRESSOR /DZSTD_EXCLUDE_BTULTRA_BLOCK_COMPRESSOR /DZSTDLIB_VISIBLE= /DZSTDERRORLIB_VISIBLE= /DZDICTLIB_VISIBLE= /DZSTDLIB_STATIC_API= /DZDICTLIB_STATIC_API= /Fo"%TEMP%\0ndb-zstd.obj" src\zstd.c || exit /b 1
if exist lib\zstd_windows_amd64.lib del lib\zstd_windows_amd64.lib
lib /nologo /out:lib\zstd_windows_amd64.lib "%TEMP%\0ndb-zstd.obj" || exit /b 1
del "%TEMP%\0ndb-zstd.obj"
