pub(crate) struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Writer { buf: Vec::new() }
    }

    pub fn u8(&mut self, v: u8) -> &mut Self {
        self.buf.push(v);
        self
    }

    pub fn uvarint(&mut self, mut v: u64) -> &mut Self {
        while v >= 0x80 {
            self.buf.push((v as u8) | 0x80);
            v >>= 7;
        }
        self.buf.push(v as u8);
        self
    }

    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.uvarint(b.len() as u64);
        self.buf.extend_from_slice(b);
        self
    }

    pub fn str(&mut self, s: &str) -> &mut Self {
        self.bytes(s.as_bytes())
    }

    pub fn bool(&mut self, v: bool) -> &mut Self {
        self.u8(v as u8)
    }

    pub fn list(&mut self, items: &[Vec<u8>]) -> &mut Self {
        self.uvarint(items.len() as u64);
        for i in items {
            self.bytes(i);
        }
        self
    }
}

pub(crate) struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
    pub ok: bool,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0, ok: true }
    }

    pub fn done(&self) -> bool {
        self.ok && self.pos == self.buf.len()
    }

    pub fn u8(&mut self) -> u8 {
        match self.buf.get(self.pos) {
            Some(b) => {
                self.pos += 1;
                *b
            }
            None => {
                self.ok = false;
                0
            }
        }
    }

    pub fn uvarint(&mut self) -> u64 {
        let mut v = 0u64;
        let mut shift = 0;
        loop {
            let b = self.u8();
            if !self.ok || shift > 63 {
                self.ok = false;
                return 0;
            }
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return v;
            }
            shift += 7;
        }
    }

    pub fn raw(&mut self, n: usize) -> &'a [u8] {
        if self.pos + n > self.buf.len() {
            self.ok = false;
            return &[];
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        s
    }

    pub fn bytes(&mut self) -> Vec<u8> {
        let n = self.uvarint() as usize;
        if n > self.buf.len() {
            self.ok = false;
            return Vec::new();
        }
        self.raw(n).to_vec()
    }

    pub fn str(&mut self) -> String {
        String::from_utf8_lossy(&self.bytes()).into_owned()
    }

    pub fn list(&mut self) -> Vec<Vec<u8>> {
        let n = self.uvarint() as usize;
        if n > self.buf.len() {
            self.ok = false;
            return Vec::new();
        }
        (0..n).map(|_| self.bytes()).collect()
    }

    pub fn id(&mut self) -> [u8; 16] {
        let mut out = [0u8; 16];
        let r = self.raw(16);
        if r.len() == 16 {
            out.copy_from_slice(r);
        }
        out
    }
}

pub fn hex(b: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push(H[(x >> 4) as usize] as char);
        s.push(H[(x & 15) as usize] as char);
    }
    s
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let v = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    };
    s.as_bytes().chunks(2).map(|p| Some(v(p[0])? << 4 | v(p[1])?)).collect()
}
