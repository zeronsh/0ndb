package libcurl

import "core:c"
import "core:dynlib"
import "core:sync"

when ODIN_OS == .Darwin {
	LIBRARY_NAMES :: [?]string{"libcurl.4.dylib", "/usr/lib/libcurl.4.dylib", "libcurl.dylib"}
} else {
	LIBRARY_NAMES :: [?]string{"libcurl.so.4", "libcurl.so"}
}

CURL :: struct {}
CURLM :: struct {}

slist :: struct {
	data: cstring,
	next: ^slist,
}

socket_t :: distinct c.int
off_t :: i64

SOCKET_BAD :: socket_t(-1)
SOCKET_TIMEOUT :: SOCKET_BAD

POLL_IN :: 1
POLL_OUT :: 2
POLL_INOUT :: 3
POLL_REMOVE :: 4

CSELECT_IN :: 0x01
CSELECT_OUT :: 0x02
CSELECT_ERR :: 0x04

READFUNC_ABORT :: 0x10000000
READFUNC_PAUSE :: 0x10000001

SEEKFUNC_OK :: 0
SEEKFUNC_FAIL :: 1
SEEKFUNC_CANTSEEK :: 2

PAUSE_CONT :: 0

HTTP_VERSION_1_1 :: 2
HTTP_VERSION_2TLS :: 4
HTTP_VERSION_2_PRIOR_KNOWLEDGE :: 5

PIPE_MULTIPLEX :: 2
ERROR_SIZE :: 256
GLOBAL_ALL :: 3

code :: enum c.int {
	E_OK                       = 0,
	E_UNSUPPORTED_PROTOCOL     = 1,
	E_URL_MALFORMAT            = 3,
	E_COULDNT_RESOLVE_PROXY    = 5,
	E_COULDNT_RESOLVE_HOST     = 6,
	E_COULDNT_CONNECT          = 7,
	E_WEIRD_SERVER_REPLY       = 8,
	E_HTTP2                    = 16,
	E_PARTIAL_FILE             = 18,
	E_WRITE_ERROR              = 23,
	E_READ_ERROR               = 26,
	E_OUT_OF_MEMORY            = 27,
	E_OPERATION_TIMEDOUT       = 28,
	E_SSL_CONNECT_ERROR        = 35,
	E_ABORTED_BY_CALLBACK      = 42,
	E_GOT_NOTHING              = 52,
	E_SEND_ERROR               = 55,
	E_RECV_ERROR               = 56,
	E_SSL_CERTPROBLEM          = 58,
	E_SSL_CIPHER               = 59,
	E_PEER_FAILED_VERIFICATION = 60,
	E_BAD_CONTENT_ENCODING     = 61,
	E_SSL_CACERT_BADFILE       = 77,
	E_HTTP2_STREAM             = 92,
}

Mcode :: enum c.int {
	OK = 0,
}

MSG :: enum c.int {
	NONE,
	DONE,
}

Msg :: struct {
	msg:         MSG,
	easy_handle: ^CURL,
	data:        struct #raw_union {
		whatever: rawptr,
		result:   code,
	},
}

option :: enum c.int {
	WRITEDATA           = 10001,
	URL                 = 10002,
	READDATA            = 10009,
	ERRORBUFFER         = 10010,
	WRITEFUNCTION       = 20011,
	READFUNCTION        = 20012,
	LOW_SPEED_LIMIT     = 19,
	LOW_SPEED_TIME      = 20,
	HTTPHEADER          = 10023,
	HEADERDATA          = 10029,
	CUSTOMREQUEST       = 10036,
	POST                = 47,
	FOLLOWLOCATION      = 52,
	CAINFO              = 10065,
	MAXREDIRS           = 68,
	HEADERFUNCTION      = 20079,
	HTTP_VERSION        = 84,
	BUFFERSIZE          = 98,
	NOSIGNAL            = 99,
	PRIVATE             = 10103,
	POSTFIELDSIZE_LARGE = 30120,
	TIMEOUT_MS          = 155,
	CONNECTTIMEOUT_MS   = 156,
	SEEKFUNCTION        = 20167,
	SEEKDATA            = 10168,
	TCP_KEEPALIVE       = 213,
	TCP_KEEPIDLE        = 214,
	TCP_KEEPINTVL       = 215,
	PIPEWAIT            = 237,
	UPLOAD_BUFFERSIZE   = 280,
}

Moption :: enum c.int {
	SOCKETFUNCTION         = 20001,
	SOCKETDATA             = 10002,
	PIPELINING             = 3,
	TIMERFUNCTION          = 20004,
	TIMERDATA              = 10005,
	MAX_CONCURRENT_STREAMS = 16,
}

INFO :: enum c.int {
	RESPONSE_CODE = 0x200000 + 2,
	PRIVATE       = 0x100000 + 21,
}

@(private)
Loader :: struct {
	mu:   sync.Mutex,
	lib:  dynlib.Library,
	refs: int,
}

@(private)
loader: Loader

global_init: proc "c" (flags: c.long) -> code
global_cleanup: proc "c" ()
easy_init: proc "c" () -> ^CURL
easy_cleanup: proc "c" (curl: ^CURL)
easy_reset: proc "c" (curl: ^CURL)
easy_setopt: proc "c" (curl: ^CURL, opt: option, #c_vararg args: ..any) -> code
easy_getinfo: proc "c" (curl: ^CURL, info: INFO, #c_vararg args: ..any) -> code
easy_strerror: proc "c" (c: code) -> cstring
easy_pause: proc "c" (curl: ^CURL, bitmask: c.int) -> code
multi_init: proc "c" () -> ^CURLM
multi_cleanup: proc "c" (m: ^CURLM) -> Mcode
multi_setopt: proc "c" (m: ^CURLM, opt: Moption, #c_vararg args: ..any) -> Mcode
multi_add_handle: proc "c" (m: ^CURLM, curl: ^CURL) -> Mcode
multi_remove_handle: proc "c" (m: ^CURLM, curl: ^CURL) -> Mcode
multi_socket_action: proc "c" (m: ^CURLM, s: socket_t, ev_bitmask: c.int, running: ^c.int) -> Mcode
multi_info_read: proc "c" (m: ^CURLM, msgs_in_queue: ^c.int) -> ^Msg
multi_assign: proc "c" (m: ^CURLM, s: socket_t, sockp: rawptr) -> Mcode
slist_append: proc "c" (list: ^slist, data: cstring) -> ^slist
slist_free_all: proc "c" (list: ^slist)

load :: proc() -> bool {
	sync.mutex_lock(&loader.mu)
	defer sync.mutex_unlock(&loader.mu)
	if loader.refs > 0 {
		loader.refs += 1
		return true
	}
	lib: dynlib.Library
	ok := false
	for name in LIBRARY_NAMES {
		if lib, ok = dynlib.load_library(name); ok {
			break
		}
	}
	if !ok {
		return false
	}
	resolved := true
	if p, found := dynlib.symbol_address(lib, "curl_global_cleanup"); found {
		global_cleanup = cast(type_of(global_cleanup))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_global_init"); found {
		global_init = cast(type_of(global_init))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_easy_init"); found {
		easy_init = cast(type_of(easy_init))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_easy_cleanup"); found {
		easy_cleanup = cast(type_of(easy_cleanup))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_easy_reset"); found {
		easy_reset = cast(type_of(easy_reset))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_easy_setopt"); found {
		easy_setopt = cast(type_of(easy_setopt))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_easy_getinfo"); found {
		easy_getinfo = cast(type_of(easy_getinfo))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_easy_strerror"); found {
		easy_strerror = cast(type_of(easy_strerror))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_easy_pause"); found {
		easy_pause = cast(type_of(easy_pause))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_init"); found {
		multi_init = cast(type_of(multi_init))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_cleanup"); found {
		multi_cleanup = cast(type_of(multi_cleanup))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_setopt"); found {
		multi_setopt = cast(type_of(multi_setopt))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_add_handle"); found {
		multi_add_handle = cast(type_of(multi_add_handle))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_remove_handle"); found {
		multi_remove_handle = cast(type_of(multi_remove_handle))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_socket_action"); found {
		multi_socket_action = cast(type_of(multi_socket_action))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_info_read"); found {
		multi_info_read = cast(type_of(multi_info_read))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_multi_assign"); found {
		multi_assign = cast(type_of(multi_assign))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_slist_append"); found {
		slist_append = cast(type_of(slist_append))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "curl_slist_free_all"); found {
		slist_free_all = cast(type_of(slist_free_all))p
	} else {
		resolved = false
	}
	if !resolved || global_init(GLOBAL_ALL) != .E_OK {
		dynlib.unload_library(lib)
		_clear()
		return false
	}
	loader.lib = lib
	loader.refs = 1
	return true
}

unload :: proc() {
	sync.mutex_lock(&loader.mu)
	defer sync.mutex_unlock(&loader.mu)
	if loader.refs == 0 {
		return
	}
	loader.refs -= 1
	if loader.refs > 0 {
		return
	}
	if global_cleanup != nil {
		global_cleanup()
	}
	dynlib.unload_library(loader.lib)
	loader.lib = nil
	_clear()
}

loaded :: proc() -> bool {
	sync.mutex_lock(&loader.mu)
	defer sync.mutex_unlock(&loader.mu)
	return loader.refs > 0
}

@(private)
_clear :: proc() {
	global_init = nil
	global_cleanup = nil
	easy_init = nil
	easy_cleanup = nil
	easy_reset = nil
	easy_setopt = nil
	easy_getinfo = nil
	easy_strerror = nil
	easy_pause = nil
	multi_init = nil
	multi_cleanup = nil
	multi_setopt = nil
	multi_add_handle = nil
	multi_remove_handle = nil
	multi_socket_action = nil
	multi_info_read = nil
	multi_assign = nil
	slist_append = nil
	slist_free_all = nil
}
