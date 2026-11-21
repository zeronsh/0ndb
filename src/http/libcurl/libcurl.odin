package libcurl

import "core:c"

when ODIN_OS == .Linux {
	foreign import lib "libcurl_runtime.so"
} else {
	foreign import lib "system:curl"
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

@(default_calling_convention = "c", link_prefix = "curl_")
foreign lib {
	global_init :: proc(flags: c.long) -> code ---
	easy_init :: proc() -> ^CURL ---
	easy_cleanup :: proc(curl: ^CURL) ---
	easy_reset :: proc(curl: ^CURL) ---
	easy_setopt :: proc(curl: ^CURL, opt: option, #c_vararg args: ..any) -> code ---
	easy_getinfo :: proc(curl: ^CURL, info: INFO, #c_vararg args: ..any) -> code ---
	easy_strerror :: proc(c: code) -> cstring ---
	easy_pause :: proc(curl: ^CURL, bitmask: c.int) -> code ---
	multi_init :: proc() -> ^CURLM ---
	multi_cleanup :: proc(m: ^CURLM) -> Mcode ---
	multi_setopt :: proc(m: ^CURLM, opt: Moption, #c_vararg args: ..any) -> Mcode ---
	multi_add_handle :: proc(m: ^CURLM, curl: ^CURL) -> Mcode ---
	multi_remove_handle :: proc(m: ^CURLM, curl: ^CURL) -> Mcode ---
	multi_socket_action :: proc(m: ^CURLM, s: socket_t, ev_bitmask: c.int, running: ^c.int) -> Mcode ---
	multi_info_read :: proc(m: ^CURLM, msgs_in_queue: ^c.int) -> ^Msg ---
	multi_assign :: proc(m: ^CURLM, s: socket_t, sockp: rawptr) -> Mcode ---
	slist_append :: proc(list: ^slist, data: cstring) -> ^slist ---
	slist_free_all :: proc(list: ^slist) ---
}
