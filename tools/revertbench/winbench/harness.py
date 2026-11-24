import ctypes, os, sys, struct, json, time, subprocess
from ctypes import wintypes

_src = os.path.join(os.environ["RB_COSTBENCH_REAL"], "harness.py")
_text = open(_src, encoding="utf-8").read()
_text = _text.replace('LIMIT = ["bash", "-c", \'ulimit -v 4000000; exec "$@"\', "x"]', "LIMIT = []")
_text = _text.replace("os.path.exists(sock)", "os.path.lexists(sock)")
exec(compile(_text, _src, "exec"), globals())
assert LIMIT == []

_k = ctypes.WinDLL("kernel32", use_last_error=True)
_k.CreateJobObjectW.restype = wintypes.HANDLE
_k.GetCurrentProcess.restype = wintypes.HANDLE
_k.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
_k.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]


class _Basic(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64), ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t), ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD), ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]


class _Ext(ctypes.Structure):
    _fields_ = [("Basic", _Basic), ("IoInfo", ctypes.c_uint64 * 6), ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]


_job = _k.CreateJobObjectW(None, None)
_e = _Ext()
_e.Basic.LimitFlags = 0x100 | 0x2000
_e.ProcessMemoryLimit = 4000000 * 1024
assert _k.SetInformationJobObject(_job, 9, ctypes.byref(_e), ctypes.sizeof(_e)), ctypes.get_last_error()
assert _k.AssignProcessToJobObject(_job, _k.GetCurrentProcess()), ctypes.get_last_error()

_w = ctypes.WinDLL("ws2_32", use_last_error=True)
_w.socket.restype = ctypes.c_size_t
_w.connect.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
_w.send.argtypes = [ctypes.c_size_t, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
_w.recv.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
_w.closesocket.argtypes = [ctypes.c_size_t]
_wsa = ctypes.create_string_buffer(1024)
assert _w.WSAStartup(0x0202, _wsa) == 0


class _Unix:
    def __init__(self, path):
        self.h = _w.socket(1, 1, 0)
        if self.h == ctypes.c_size_t(-1).value:
            raise OSError("socket %d" % ctypes.get_last_error())
        sa = struct.pack("<H108s", 1, path.replace("/", "\\").encode())
        if _w.connect(self.h, sa, len(sa)) != 0:
            e = _w.WSAGetLastError()
            _w.closesocket(self.h)
            raise OSError("connect %s: %d" % (path, e))

    def sendall(self, data):
        while data:
            n = _w.send(self.h, data, len(data), 0)
            if n <= 0:
                raise OSError("send %d" % _w.WSAGetLastError())
            data = data[n:]

    def recv(self, n):
        b = ctypes.create_string_buffer(n)
        r = _w.recv(self.h, b, n, 0)
        if r < 0:
            raise OSError("recv %d" % _w.WSAGetLastError())
        return b.raw[:r]

    def close(self):
        _w.closesocket(self.h)


def _client_init(self, sock_path):
    self.s = _Unix(sock_path)
    self.s.sendall(b"0NDB\x01")
    self.tag = 0
    self.buf = b""


Client.__init__ = _client_init


def term(p, timeout=30):
    if p.poll() is None:
        p.kill()
        p.wait(timeout=10)


def cleanup():
    for p in PROCS:
        if p.poll() is None:
            p.kill()


def _relay_stop(self):
    term(self.proc)
    return {}


Relay.stop = _relay_stop
