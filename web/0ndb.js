const OP = { catalog: 1, status: 2, page: 3, message: 4, siblings: 5, mapGet: 6, mapScan: 7, subscribe: 8, unsubscribe: 9, text: 10, catalogEntry: 11, close: 12, window: 13, switch: 14 };
const EV_RESULT = 1, EV_DELTAS = 2, EV_CONNECTED = 3, EV_CLOSED = 4, EV_INFO = 5, EV_APPROVAL = 6;
const STATUS = ['ok', 'missing', 'corrupt', 'invalid', 'not_found', 'exists', 'busy', 'limit', 'too_large', 'unsupported', 'not_assigned', 'unknown_segment', 'forged', 'permission', 'no_space', 'no_memory', 'io'];
const SYNC_ERRORS = ['none', 'invalid', 'corrupt', 'auth', 'protocol', 'closed', 'would_block', 'not_found', 'exists', 'permission', 'no_space', 'no_memory', 'too_large', 'busy', 'quota', 'conflict', 'unsupported', 'timeout', 'resolve', 'refused', 'io'];
const KINDS = { conversation: 1, map: 2 };
const enc = new TextEncoder();
const dec = new TextDecoder();

export class OndbError extends Error {
  constructor(code, message) {
    super(message || code);
    this.code = code;
  }
}

function statusName(s) {
  if (s === 252) return 'closed';
  if (s === 253) return 'bad_args';
  if (s === 254) return 'unsupported';
  return STATUS[s] || 'status_' + s;
}

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function hexToBytes(hex, out, at) {
  if (typeof hex !== 'string' || hex.length !== 32) throw new OndbError('invalid', 'expected a 32-character id');
  for (let i = 0; i < 16; i++) {
    const v = parseInt(hex.substr(i * 2, 2), 16);
    if (Number.isNaN(v)) throw new OndbError('invalid', 'expected a hex id');
    out[at + i] = v;
  }
}

function putRid(view, bytes, at, rid) {
  if (rid == null) return;
  const [seg, off, gen = '0'] = String(rid).split(':');
  hexToBytes(seg, bytes, at);
  view.setBigUint64(at + 16, BigInt(off), true);
  view.setBigUint64(at + 24, BigInt(gen), true);
}

function toBytes(v) {
  if (v == null) return new Uint8Array(0);
  if (typeof v === 'string') return enc.encode(v);
  if (v instanceof Uint8Array) return v;
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  return new Uint8Array(v);
}

function fromHex(h) {
  if (!h) return new Uint8Array(0);
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}

export class Ondb {
  static async load(source) {
    let mod;
    if (source instanceof WebAssembly.Module) mod = source;
    else if (source instanceof Uint8Array || source instanceof ArrayBuffer) mod = await WebAssembly.compile(source);
    else if (typeof Response !== 'undefined' && source instanceof Response) mod = await WebAssembly.compileStreaming(source);
    else mod = await WebAssembly.compileStreaming(fetch(source));
    const lib = new Ondb();
    const inst = await WebAssembly.instantiate(mod, { odin_env: lib._env() });
    lib.x = inst.exports;
    if (lib.x._start) lib.x._start();
    return lib;
  }

  _env() {
    return {
      rand_bytes: (ptr, len) => crypto.getRandomValues(new Uint8Array(this.x.memory.buffer, ptr, len)),
      write: (fd, ptr, len) => console.error(dec.decode(new Uint8Array(this.x.memory.buffer, ptr, len))),
    };
  }

  _with(bytes, fn) {
    const n = bytes.length;
    const p = n ? this.x.ondb_alloc(n) : 0;
    if (n && !p) throw new OndbError('no_memory');
    if (n) new Uint8Array(this.x.memory.buffer, p, n).set(bytes);
    try {
      return fn(p, n);
    } finally {
      if (n) this.x.ondb_free(p, n);
    }
  }

  session({ seed } = {}) {
    const s = this._with(toBytes(seed), (p, n) => this.x.ondb_new(p, n));
    if (!s) throw new OndbError('invalid', 'cannot create a session');
    return new Space(this, s);
  }

  async open(credential, { seed, store, compactRatio = 4 } = {}) {
    const sp = this.session({ seed });
    try {
      if (store) await sp.restore(store, { compactRatio });
      sp.join(credential);
    } catch (e) {
      sp.close();
      throw e;
    }
    return sp;
  }

  join(credential, { seed } = {}) {
    const sp = this.session({ seed });
    try {
      sp.join(credential);
    } catch (e) {
      sp.close();
      throw e;
    }
    return sp;
  }

  _result() {
    const n = this.x.ondb_result_len(this._probe);
    return new Uint8Array(this.x.memory.buffer, this.x.ondb_result_ptr(this._probe), n).slice();
  }

  _scratch() {
    if (!this._probe) {
      this._probe = this._with(new Uint8Array(0), () => this.x.ondb_new(0, 0));
      if (!this._probe) throw new OndbError('no_memory');
    }
    return this._probe;
  }

  unlockOptions(record) {
    const s = this._scratch();
    const err = this._with(toBytes(record), (p, n) => this.x.ondb_account_options(s, p, n));
    if (err) throw new OndbError(SYNC_ERRORS[err] || 'corrupt', 'account record is damaged');
    const r = this._result();
    const dv = new DataView(r.buffer);
    const out = [];
    let at = 4;
    for (let i = 0, count = dv.getUint32(0, true); i < count; i++) {
      const len = dv.getUint32(at, true);
      at += 4;
      out.push({ credential: r.slice(at, at + len), salt: r.slice(at + len, at + len + 32) });
      at += len + 32;
    }
    return out;
  }

  idpSalt(subject) {
    const s = this._scratch();
    this._with(enc.encode(String(subject)), (p, n) => this.x.ondb_idp_salt(s, p, n));
    return this._result();
  }

  async unlock(record, { rpId, mediation } = {}) {
    const options = this.unlockOptions(record);
    if (!options.length) throw new OndbError('not_found', 'no passkey is registered for this account');
    const evalByCredential = {};
    for (const o of options) evalByCredential[b64url(o.credential)] = { first: o.salt };
    const cred = await navigator.credentials.get({
      mediation,
      publicKey: {
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        rpId,
        userVerification: 'required',
        allowCredentials: options.map((o) => ({ type: 'public-key', id: o.credential })),
        extensions: { prf: { evalByCredential } },
      },
    });
    const prf = cred && cred.getClientExtensionResults().prf;
    const first = prf && prf.results && prf.results.first;
    if (!first) throw new OndbError('unsupported', 'this passkey provider does not return PRF output');
    return { credential: new Uint8Array(cred.rawId), prf: new Uint8Array(first) };
  }

  async signIn({ record, entries, space, rpId, seed, store, compactRatio = 4, credential, prf } = {}) {
    if (!credential || !prf) ({ credential, prf } = await this.unlock(record, { rpId }));
    const sp = this.session({ seed });
    try {
      if (store) await sp.restore(store, { compactRatio });
      sp.openAccount({ record, entries, credential, prf, space });
    } catch (e) {
      sp.close();
      throw e;
    }
    return sp;
  }

  async approver({ record, rpId, seed, credential, prf } = {}) {
    if (!credential || !prf) ({ credential, prf } = await this.unlock(record, { rpId }));
    const sp = this.session({ seed });
    const rec = toBytes(record);
    const err = this._with(rec, (rp, rn) => this._with(toBytes(credential), (cp, cn) => this._with(toBytes(prf), (pp) => this.x.ondb_approver_open(sp.s, rp, rn, cp, cn, pp))));
    if (err) {
      sp.close();
      throw new OndbError(SYNC_ERRORS[err] || 'auth', 'cannot unlock the account');
    }
    return sp;
  }

  get memoryBytes() {
    return this.x.memory.buffer.byteLength;
  }
}

export class Space {
  constructor(lib, ptr) {
    this.lib = lib;
    this.x = lib.x;
    this.s = ptr;
    this.pending = new Map();
    this.feeds = new Map();
    this.transport = null;
    this.connected = false;
    this.waiters = [];
    this.listeners = new Set();
    this.closed = false;
    this._info = null;
  }

  openAccount({ record, entries, credential, prf, space }) {
    const L = this.lib;
    const sp = space ? (() => { const b = new Uint8Array(16); hexToBytes(space, b, 0); return b; })() : new Uint8Array(0);
    const err = L._with(toBytes(record), (rp, rn) => L._with(toBytes(entries), (ep, en) => L._with(toBytes(credential), (cp, cn) => L._with(toBytes(prf), (pp) => L._with(sp, (sp2) => this.x.ondb_account_open(this.s, rp, rn, ep, en, cp, cn, pp, sp2))))));
    if (err) throw new OndbError(SYNC_ERRORS[err] || 'auth', 'cannot sign in with that passkey');
    return this;
  }

  join(credential) {
    const err = this.lib._with(enc.encode(String(credential).trim()), (p, n) => this.x.ondb_join(this.s, p, n));
    if (err) throw new OndbError(SYNC_ERRORS[err] || 'error', 'cannot open the credential');
    return this;
  }

  async restore(store, { compactRatio = 4 } = {}) {
    const blobs = await store.load();
    let stored = 0;
    for (const b of blobs) {
      const err = this.lib._with(toBytes(b), (p, n) => this.x.ondb_restore(this.s, p, n));
      if (err) throw new OndbError('corrupt', 'stored replica log is damaged');
      stored += b.byteLength;
    }
    this.store = store;
    this.stored = stored;
    this.compactRatio = compactRatio;
    this.persisting = Promise.resolve();
    this.x.ondb_persist(this.s, 1);
  }

  flushed() {
    return this.persisting || Promise.resolve();
  }

  _persist() {
    const x = this.x;
    const n = x.ondb_log_len(this.s);
    if (!n) return;
    const blob = new Uint8Array(x.memory.buffer, x.ondb_log_ptr(this.s), n).slice();
    x.ondb_log_clear(this.s);
    this.stored += n;
    const store = this.store;
    this.persisting = this.persisting.then(() => store.append(blob));
    const live = x.ondb_resident(this.s);
    if (this.stored > (1 << 20) && this.stored > this.compactRatio * live) {
      const m = x.ondb_snapshot(this.s);
      const snap = new Uint8Array(x.memory.buffer, x.ondb_log_ptr(this.s), m).slice();
      x.ondb_log_clear(this.s);
      this.stored = m;
      this.persisting = this.persisting.then(() => store.replace(snap));
    }
  }

  get card() {
    return this.info().card;
  }

  on(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  attach(transport) {
    this.transport = transport;
    const err = this.x.ondb_connect(this.s);
    if (err) throw new OndbError(SYNC_ERRORS[err] || 'error');
    this._pump();
  }

  input(data) {
    if (this.closed) return;
    const bytes = toBytes(data);
    const err = this.lib._with(bytes, (p, n) => this.x.ondb_input(this.s, p, n));
    this._pump();
    if (err && this.transport) {
      const t = this.transport;
      this.transport = null;
      t.close();
    }
  }

  down() {
    if (this.closed) return;
    this.transport = null;
    this.x.ondb_down(this.s);
    this._pump();
  }

  connect(url, { WebSocket: WS = globalThis.WebSocket, retry = true } = {}) {
    let delay = 250;
    const open = () => {
      if (this.closed) return;
      const ws = new WS(url);
      ws.binaryType = 'arraybuffer';
      let up = false;
      ws.onopen = () => {
        up = true;
        delay = 250;
        this.attach({ send: (b) => ws.send(b), close: () => ws.close() });
      };
      ws.onmessage = (ev) => this.input(new Uint8Array(ev.data));
      ws.onclose = () => {
        if (up) this.down();
        if (retry && !this.closed) {
          setTimeout(open, delay);
          delay = Math.min(delay * 2, 30000);
        }
      };
      ws.onerror = () => {};
      this.ws = ws;
    };
    open();
    return this.ready();
  }

  ready() {
    if (this.connected) return Promise.resolve();
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  _pump() {
    const x = this.x;
    if (this.store) this._persist();
    let n = x.ondb_out_len(this.s);
    if (n && this.transport) {
      const out = new Uint8Array(x.memory.buffer, x.ondb_out_ptr(this.s), n).slice();
      x.ondb_out_clear(this.s);
      this.transport.send(out);
    }
    n = x.ondb_ev_len(this.s);
    if (!n) return;
    const ev = new Uint8Array(x.memory.buffer, x.ondb_ev_ptr(this.s), n).slice();
    x.ondb_ev_clear(this.s);
    const dv = new DataView(ev.buffer);
    let p = 0;
    while (p + 10 <= ev.length) {
      const kind = ev[p];
      const id = dv.getUint32(p + 1, true);
      const status = ev[p + 5];
      const len = dv.getUint32(p + 6, true);
      const body = ev.subarray(p + 10, p + 10 + len);
      p += 10 + len;
      this._event(kind, id, status, body);
    }
  }

  _event(kind, id, status, body) {
    switch (kind) {
      case EV_RESULT: {
        const w = this.pending.get(id);
        if (!w) return;
        this.pending.delete(id);
        if (status === 0) w.resolve(body.length ? JSON.parse(dec.decode(body)) : {});
        else w.reject(new OndbError(statusName(status)));
        return;
      }
      case EV_DELTAS: {
        const f = this.feeds.get(id);
        if (f) f.push(JSON.parse(dec.decode(body)));
        return;
      }
      case EV_CONNECTED:
        this.connected = true;
        for (const w of this.waiters.splice(0)) w();
        for (const fn of this.listeners) fn({ type: 'connected' });
        return;
      case EV_CLOSED:
        this.connected = false;
        for (const fn of this.listeners) fn({ type: 'closed' });
        return;
      case EV_INFO:
        this._info = JSON.parse(dec.decode(body));
        return;
      case EV_APPROVAL: {
        const code = dec.decode(body.subarray(0, 8));
        const label = dec.decode(body.subarray(8));
        for (const fn of this.listeners) fn({ type: 'approval', code, label });
        return;
      }
    }
  }

  approve(code, ok = true) {
    const norm = String(code).replace(/[-\s]/g, '').toLowerCase();
    const err = this.lib._with(enc.encode(norm), (p, n) => this.x.ondb_approve(this.s, p, n, ok ? 1 : 0));
    if (err) throw new OndbError(SYNC_ERRORS[err] || 'error', 'cannot answer that approval');
    this._pump();
  }

  _request(op, args) {
    if (this.closed) return Promise.reject(new OndbError('closed'));
    return new Promise((resolve, reject) => {
      const id = this.lib._with(args, (p, n) => this.x.ondb_request(this.s, op, p, n));
      this.pending.set(id, { resolve, reject });
      this._pump();
    });
  }

  catalog({ archived = false, limit = 50, cursor = '' } = {}) {
    const c = fromHex(cursor);
    const a = new Uint8Array(5 + c.length);
    a[0] = archived ? 1 : 0;
    new DataView(a.buffer).setUint32(1, limit, true);
    a.set(c, 5);
    return this._request(OP.catalog, a);
  }

  catalogEntry(object) {
    const a = new Uint8Array(16);
    hexToBytes(object, a, 0);
    return this._request(OP.catalogEntry, a);
  }

  status(object) {
    const a = new Uint8Array(16);
    hexToBytes(object, a, 0);
    return this._request(OP.status, a);
  }

  page(object, { from = null, limit = 32, dir = 'older', leaf = null } = {}) {
    const a = new Uint8Array(118);
    const dv = new DataView(a.buffer);
    hexToBytes(object, a, 0);
    if (from) {
      putRid(dv, a, 16, from.msg);
      putRid(dv, a, 48, from.seal);
      a[80] = from.seal_known ? 1 : 0;
    }
    dv.setUint32(81, limit, true);
    a[85] = dir === 'newer' ? 1 : 0;
    putRid(dv, a, 86, leaf);
    return this._request(OP.page, a);
  }

  window(object, anchor, { before = 16, after = 16, leaf = null } = {}) {
    const a = new Uint8Array(88);
    const dv = new DataView(a.buffer);
    hexToBytes(object, a, 0);
    putRid(dv, a, 16, anchor);
    dv.setUint32(48, before, true);
    dv.setUint32(52, after, true);
    putRid(dv, a, 56, leaf);
    return this._request(OP.window, a);
  }

  peekSwitch(object, sibling, { before = 16, after = 16 } = {}) {
    const a = new Uint8Array(56);
    const dv = new DataView(a.buffer);
    hexToBytes(object, a, 0);
    putRid(dv, a, 16, sibling);
    dv.setUint32(48, before, true);
    dv.setUint32(52, after, true);
    return this._request(OP.switch, a);
  }

  message(object, rid) {
    return this._rid(OP.message, object, rid);
  }

  siblings(object, rid) {
    return this._rid(OP.siblings, object, rid);
  }

  _rid(op, object, rid) {
    const a = new Uint8Array(48);
    hexToBytes(object, a, 0);
    putRid(new DataView(a.buffer), a, 16, rid);
    return this._request(op, a);
  }

  mapGet(object, key) {
    const k = toBytes(key);
    const a = new Uint8Array(16 + k.length);
    hexToBytes(object, a, 0);
    a.set(k, 16);
    return this._request(OP.mapGet, a);
  }

  mapScan(object, { prefix = '', limit = 50, cursor = '' } = {}) {
    const pf = toBytes(prefix);
    const c = fromHex(cursor);
    const a = new Uint8Array(24 + pf.length + c.length);
    const dv = new DataView(a.buffer);
    hexToBytes(object, a, 0);
    dv.setUint32(16, limit, true);
    dv.setUint32(20, pf.length, true);
    a.set(pf, 24);
    a.set(c, 24 + pf.length);
    return this._request(OP.mapScan, a);
  }

  text(object) {
    const a = new Uint8Array(16);
    hexToBytes(object, a, 0);
    return this._request(OP.text, a);
  }

  follow(object, kind = 'conversation') {
    const a = new Uint8Array(17);
    hexToBytes(object, a, 0);
    a[16] = KINDS[kind] || 1;
    const queue = [];
    const takers = [];
    let sub = 0;
    let done = false;
    const feed = {
      push: (deltas) => {
        if (takers.length) takers.shift()({ value: deltas, done: false });
        else queue.push(deltas);
      },
    };
    const started = this._request(OP.subscribe, a).then((r) => {
      sub = r.sub;
      this.feeds.set(sub, feed);
      return sub;
    });
    const end = async () => {
      done = true;
      await started;
      this.feeds.delete(sub);
      const u = new Uint8Array(4);
      new DataView(u.buffer).setUint32(0, sub, true);
      await this._request(OP.unsubscribe, u).catch(() => {});
      for (const t of takers.splice(0)) t({ value: undefined, done: true });
      return { value: undefined, done: true };
    };
    return {
      started,
      [Symbol.asyncIterator]() {
        return this;
      },
      next: async () => {
        await started;
        if (queue.length) return { value: queue.shift(), done: false };
        if (done) return { value: undefined, done: true };
        return new Promise((resolve) => takers.push(resolve));
      },
      return: end,
    };
  }

  release(object) {
    const a = new Uint8Array(16);
    hexToBytes(object, a, 0);
    return this._request(OP.close, a);
  }

  info() {
    this.x.ondb_info(this.s);
    this._pump();
    return this._info;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    if (this.ws) this.ws.close();
    for (const w of this.pending.values()) w.reject(new OndbError('closed'));
    this.pending.clear();
    this.x.ondb_close(this.s);
  }
}

export function indexedDBStore(name, idb = globalThis.indexedDB) {
  const req = (r) => new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  const done = (t) => new Promise((resolve, reject) => {
    t.oncomplete = () => resolve();
    t.onerror = t.onabort = () => reject(t.error);
  });
  let db = null;
  const open = async () => {
    if (db) return db;
    const r = idb.open('0ndb:' + name, 1);
    r.onupgradeneeded = () => r.result.createObjectStore('log', { autoIncrement: true });
    db = await req(r);
    return db;
  };
  return {
    async load() {
      const d = await open();
      const all = await req(d.transaction('log', 'readonly').objectStore('log').getAll());
      return all.map((b) => new Uint8Array(b));
    },
    async append(blob) {
      const t = (await open()).transaction('log', 'readwrite');
      t.objectStore('log').add(blob.buffer);
      await done(t);
    },
    async replace(blob) {
      const t = (await open()).transaction('log', 'readwrite');
      const os = t.objectStore('log');
      os.clear();
      os.add(blob.buffer);
      await done(t);
    },
    async clear() {
      const t = (await open()).transaction('log', 'readwrite');
      t.objectStore('log').clear();
      await done(t);
    },
  };
}

function opLen(o, utf16) {
  if (o.kind === 'insert') return utf16 ? o.text.length : enc.encode(o.text).length;
  return o.n;
}

function pushOp(out, o) {
  if (o.kind !== 'insert' && !(o.n > 0)) return;
  if (o.kind === 'insert' && !o.text) return;
  const l = out[out.length - 1];
  if (l && l.kind === o.kind && o.kind !== 'insert') {
    l.n += o.n;
    return;
  }
  out.push({ ...o });
}

function trimOps(out) {
  while (out.length && out[out.length - 1].kind === 'retain') out.pop();
  return out;
}

export function transformDelta(a, b, utf16 = true) {
  const ao = [], bo = [];
  let i = 0, j = 0, ui = 0, uj = 0;
  const peek = (ops, k, used) => (k < ops.length ? [ops[k], opLen(ops[k], utf16) - used] : [{ kind: 'retain' }, Infinity]);
  for (;;) {
    const [oa, ra] = peek(a, i, ui);
    const [ob, rb] = peek(b, j, uj);
    if (i >= a.length && j >= b.length) break;
    if (i < a.length && oa.kind === 'insert') {
      pushOp(ao, oa);
      pushOp(bo, { kind: 'retain', n: ra });
      i++; ui = 0;
      continue;
    }
    if (j < b.length && ob.kind === 'insert') {
      pushOp(ao, { kind: 'retain', n: rb });
      pushOp(bo, ob);
      j++; uj = 0;
      continue;
    }
    const k = Math.min(ra, rb);
    if (oa.kind === 'retain' && ob.kind === 'retain') {
      pushOp(ao, { kind: 'retain', n: k });
      pushOp(bo, { kind: 'retain', n: k });
    } else if (oa.kind === 'delete' && ob.kind === 'retain') {
      pushOp(ao, { kind: 'delete', n: k });
    } else if (oa.kind === 'retain' && ob.kind === 'delete') {
      pushOp(bo, { kind: 'delete', n: k });
    }
    if (i < a.length) { ui += k; if (ui >= opLen(a[i], utf16)) { i++; ui = 0; } }
    if (j < b.length) { uj += k; if (uj >= opLen(b[j], utf16)) { j++; uj = 0; } }
  }
  return [trimOps(ao), trimOps(bo)];
}

export function transformPosition(ops, pos, after = false, utf16 = true) {
  let old = 0, shift = 0;
  for (const o of ops) {
    const n = opLen(o, utf16);
    if (o.kind === 'retain') {
      if (pos < old + n) return pos + shift;
      old += n;
    } else if (o.kind === 'insert') {
      if (pos === old && !after) return pos + shift;
      shift += n;
    } else {
      if (pos <= old) return pos + shift;
      if (pos < old + n) return old + shift;
      shift -= n;
      old += n;
    }
  }
  return pos + shift;
}

export function applyDelta(text, ops) {
  let out = '', at = 0;
  for (const o of ops) {
    if (o.kind === 'retain') { out += text.slice(at, at + o.n); at += o.n; }
    else if (o.kind === 'delete') at += o.n;
    else out += o.text;
  }
  return out + text.slice(at);
}

function editsToOps(edits, utf16) {
  const ops = [];
  let at = 0;
  for (const e of edits) {
    if (e.pos < at) throw new OndbError('invalid', 'edits must be sorted and non-overlapping');
    pushOp(ops, { kind: 'retain', n: e.pos - at });
    pushOp(ops, { kind: 'delete', n: e.del || 0 });
    if (e.ins) pushOp(ops, { kind: 'insert', n: opLen({ kind: 'insert', text: e.ins }, utf16), text: e.ins });
    at = e.pos + (e.del || 0);
  }
  return trimOps(ops);
}

class Runs {
  constructor(text, total) {
    this.runs = [];
    if (text) this.runs.push({ s: text });
    if (total > text.length) this.runs.push({ hole: total - text.length });
  }
  get length() {
    let n = 0;
    for (const r of this.runs) n += r.s != null ? r.s.length : r.hole;
    return n;
  }
  holes() {
    const out = [];
    let at = 0;
    for (const r of this.runs) {
      const n = r.s != null ? r.s.length : r.hole;
      if (r.hole) out.push([at, n]);
      at += n;
    }
    return out;
  }
  text() {
    return this.runs.map((r) => (r.s != null ? r.s : '\u0000'.repeat(r.hole))).join('');
  }
  _split(pos) {
    let at = 0;
    for (let i = 0; i < this.runs.length; i++) {
      const r = this.runs[i];
      const n = r.s != null ? r.s.length : r.hole;
      if (pos === at) return i;
      if (pos < at + n) {
        const k = pos - at;
        const [a, b] = r.s != null ? [{ s: r.s.slice(0, k) }, { s: r.s.slice(k) }] : [{ hole: k }, { hole: n - k }];
        this.runs.splice(i, 1, a, b);
        return i + 1;
      }
      at += n;
    }
    return this.runs.length;
  }
  _norm() {
    const out = [];
    for (const r of this.runs) {
      const n = r.s != null ? r.s.length : r.hole;
      if (!n) continue;
      const l = out[out.length - 1];
      if (l && l.s != null && r.s != null) l.s += r.s;
      else if (l && l.hole && r.hole) l.hole += r.hole;
      else out.push({ ...r });
    }
    this.runs = out;
  }
  apply(ops) {
    let at = 0;
    for (const o of ops) {
      if (o.kind === 'retain') at += o.n;
      else if (o.kind === 'delete') {
        const a = this._split(at), b = this._split(at + o.n);
        this.runs.splice(a, b - a);
      } else {
        const a = this._split(at);
        this.runs.splice(a, 0, { s: o.text });
        at += o.text.length;
      }
    }
    this._norm();
  }
  fill(pos, text) {
    for (let k = 0; k < text.length; ) {
      let at = 0, done = false;
      for (let i = 0; i < this.runs.length && !done; i++) {
        const r = this.runs[i];
        const n = r.s != null ? r.s.length : r.hole;
        if (pos + k < at + n) {
          const take = Math.min(at + n - (pos + k), text.length - k);
          if (r.hole) {
            const a = this._split(pos + k), b = this._split(pos + k + take);
            this.runs.splice(a, b - a, { s: text.slice(k, k + take) });
            this._norm();
          }
          k += take;
          done = true;
        }
        at += n;
      }
      if (!done) break;
    }
  }
}

export class LiveBuffer {
  constructor(transport, open, units) {
    this.t = transport;
    this.utf16 = units !== 'bytes';
    this.id = open.buffer;
    this.rev = open.rev;
    this.seq = 0;
    this.pending = [];
    this.doc = new Runs(open.text || '', open.length);
    this.actor = open.actor;
    this.line = open.line;
    this.listeners = new Set();
    this.cursors = [];
    this.acks = [];
  }

  static async open(transport, { object, path = '', line = '', units = 'utf16', actor, page = 65536 } = {}) {
    let lb = null;
    const early = [];
    const sub = await transport.subscribe({ op: 'buffer.open', object, path, line, units, actor, page }, (ev) => {
      if (lb) lb._event(ev);
      else early.push(ev);
    });
    lb = new LiveBuffer(transport, sub.result, units);
    lb.sub = sub;
    for (const ev of early) lb._event(ev);
    return lb;
  }

  get text() {
    return this.doc.text();
  }

  get loaded() {
    return this.doc.holes().length === 0;
  }

  on(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  _emit(change) {
    for (const fn of this.listeners) fn(change);
  }

  _acked(ack) {
    while (this.pending.length && this.pending[0].seq <= ack) this.pending.shift();
  }

  _event(ev) {
    if (ev.kind === 'delta') {
      this._acked(ev.ack);
      let d = ev.ops;
      for (const p of this.pending) {
        const [p2, d2] = transformDelta(p.ops, d, this.utf16);
        p.ops = p2;
        d = d2;
      }
      this.doc.apply(d);
      this.rev = ev.rev;
      while (this.acks.length && this.acks[0].rev <= this.rev) this._acked(this.acks.shift().ack);
      this.cursors = this.cursors.map((c) => ({ ...c, ranges: c.ranges.map((r) => ({ anchor: transformPosition(d, r.anchor, true, this.utf16), head: transformPosition(d, r.head, true, this.utf16) })) }));
      this._emit({ kind: 'delta', ops: d, rev: ev.rev });
    } else if (ev.kind === 'cursors') {
      this.cursors = ev.cursors.map((c) => ({ ...c, ranges: c.ranges.map((r) => ({ anchor: this._local(r.anchor, ev.ack, true), head: this._local(r.head, ev.ack, true) })) }));
      this._emit({ kind: 'cursors', cursors: this.cursors });
    } else if (ev.kind === 'closed') {
      this._emit({ kind: 'closed', status: ev.status });
    }
  }

  _local(pos, ack, after) {
    if (pos < 0) return pos;
    let p = pos;
    for (const e of this.pending) if (e.seq > ack) p = transformPosition(e.ops, p, after, this.utf16);
    return p;
  }

  edit(edits, group = 0) {
    const ops = editsToOps(edits, this.utf16);
    if (!ops.length) return Promise.resolve(this.seq);
    this.doc.apply(ops);
    this.seq++;
    const seq = this.seq;
    this.pending.push({ seq, ops });
    const call = this.t.call({
      op: 'buffer.edit', buffer: this.id, rev: this.rev, group,
      pos: edits.map((e) => e.pos), del: edits.map((e) => e.del || 0), ins: edits.map((e) => e.ins || ''),
    });
    return call.then((r) => {
      if (r.rev <= this.rev) this._acked(r.ack);
      else this.acks.push({ rev: r.rev, ack: r.ack });
      return r.ack;
    });
  }

  async read(from, len) {
    const r = await this.t.call({ op: 'buffer.read', buffer: this.id, rev: this.rev, from, len });
    this.doc.fill(this._local(r.from, r.ack, false), r.text);
    return r;
  }

  async loadAll(chunk = 1 << 16) {
    for (let h = this.doc.holes(); h.length; h = this.doc.holes()) {
      const [at, n] = h[0];
      await this.read(at, Math.min(n, chunk));
    }
  }

  async anchors(positions, bias = 'before') {
    const r = await this.t.call({ op: 'buffer.anchors', buffer: this.id, rev: this.rev, positions, bias });
    return r.anchors;
  }

  async resolve(anchors) {
    const r = await this.t.call({ op: 'buffer.resolve', buffer: this.id, anchors });
    return r.positions.map((p) => this._local(p, r.ack, false));
  }

  setCursors(ranges) {
    return this.t.call({ op: 'buffer.cursors', buffer: this.id, rev: this.rev, ranges: ranges.flatMap((r) => [r.anchor, r.head]) });
  }

  undo() {
    return this.t.call({ op: 'buffer.undo', buffer: this.id }).then((r) => r.done);
  }

  redo() {
    return this.t.call({ op: 'buffer.redo', buffer: this.id }).then((r) => r.done);
  }

  ack() {
    return this.t.call({ op: 'buffer.ack', buffer: this.id, rev: this.rev });
  }

  close() {
    if (this.sub) this.sub.unsubscribe();
  }
}
