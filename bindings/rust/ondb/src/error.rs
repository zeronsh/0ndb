use std::fmt;

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Status(pub u8);

const NAMES: [&str; 27] = [
    "ok",
    "pending",
    "not_found",
    "exists",
    "invalid",
    "busy",
    "closed",
    "offline",
    "permission",
    "forged",
    "quarantined",
    "missing",
    "corrupt",
    "limit",
    "too_large",
    "unsupported",
    "not_assigned",
    "no_space",
    "no_memory",
    "io",
    "bad_request",
    "unknown_op",
    "conflict",
    "cancelled",
    "budget",
    "spawn",
    "timeout",
];

impl Status {
    pub const OK: Status = Status(0);
    pub const PENDING: Status = Status(1);
    pub const NOT_FOUND: Status = Status(2);
    pub const EXISTS: Status = Status(3);
    pub const INVALID: Status = Status(4);
    pub const BUSY: Status = Status(5);
    pub const CLOSED: Status = Status(6);
    pub const OFFLINE: Status = Status(7);
    pub const PERMISSION: Status = Status(8);
    pub const FORGED: Status = Status(9);
    pub const QUARANTINED: Status = Status(10);
    pub const MISSING: Status = Status(11);
    pub const CORRUPT: Status = Status(12);
    pub const LIMIT: Status = Status(13);
    pub const TOO_LARGE: Status = Status(14);
    pub const UNSUPPORTED: Status = Status(15);
    pub const NOT_ASSIGNED: Status = Status(16);
    pub const NO_SPACE: Status = Status(17);
    pub const NO_MEMORY: Status = Status(18);
    pub const IO: Status = Status(19);
    pub const BAD_REQUEST: Status = Status(20);
    pub const UNKNOWN_OP: Status = Status(21);
    pub const CONFLICT: Status = Status(22);
    pub const CANCELLED: Status = Status(23);
    pub const BUDGET: Status = Status(24);
    pub const SPAWN: Status = Status(25);
    pub const TIMEOUT: Status = Status(26);

    pub fn name(self) -> &'static str {
        NAMES.get(self.0 as usize).copied().unwrap_or("unknown")
    }

    pub fn from_name(name: &str) -> Option<Status> {
        NAMES.iter().position(|n| *n == name).map(|i| Status(i as u8))
    }
}

impl fmt::Debug for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Status({})", self.name())
    }
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

#[derive(Debug)]
pub enum Error {
    Status(Status),
    Disconnected,
    Io(std::io::Error),
    Protocol(String),
    Decode(serde_json::Error),
    Start(String),
}

impl Error {
    pub fn status(&self) -> Option<Status> {
        match self {
            Error::Status(s) => Some(*s),
            _ => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Status(s) => write!(f, "the daemon answered {s}"),
            Error::Disconnected => f.write_str("the connection to the daemon is gone"),
            Error::Io(e) => write!(f, "socket error: {e}"),
            Error::Protocol(m) => write!(f, "protocol error: {m}"),
            Error::Decode(e) => write!(f, "cannot decode the daemon's answer: {e}"),
            Error::Start(m) => write!(f, "cannot start the daemon: {m}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(e) => Some(e),
            Error::Decode(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::Decode(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;
