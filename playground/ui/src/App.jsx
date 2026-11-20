import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Escape, MugenVList, VStack, useMugenSelector, useMugenVirtualizer } from '@wingleeio/mugen';
import { ArrowDown, ArrowUp, FolderGit2, FolderPlus, MessageCircle, MessageSquarePlus, Plus, RefreshCw, Square, Trash2, X } from 'lucide-react';
import { api } from './api.js';
import { TurnRow, handlers } from './TurnRow.jsx';
import { ModelPicker } from './ModelPicker.jsx';
import { presentTool } from './toolPresentation.js';
import { applyReasoningDelta, mergeReasoning } from './reasoning.js';
import HistoryPane from './HistoryPane.jsx';
import ForkBar from './ForkBar.jsx';

const PICKER_KEY = 'ondb-playground.picker';

function loadPicker() {
  try {
    return JSON.parse(localStorage.getItem(PICKER_KEY)) || {};
  } catch {
    return {};
  }
}

function savePicker(p) {
  localStorage.setItem(PICKER_KEY, JSON.stringify(p));
}

export function App() {
  const [state, setState] = useState({ providers: [], worktrees: [], threads: [], warm: 0 });
  const [worktree, setWorktree] = useState(null);
  const [thread, setThread] = useState(null);
  const [messages, setMessages] = useState([]);
  const [hasMore, setHasMore] = useState(false);
  const [sessions, setSessions] = useState([]);
  const [live, setLive] = useState({});
  const [liveReasoning, setLiveReasoning] = useState({});
  const liveReasoningRef = useRef({});
  const messagesRef = useRef(messages);
  messagesRef.current = messages;
  const [pending, setPending] = useState(null);
  const [provider, setProvider] = useState(() => loadPicker().provider || 'mock');
  const [model, setModel] = useState(() => {
    const p = loadPicker();
    return p.models?.[p.provider || 'mock'] || '';
  });
  const pick = useCallback((nextProvider, nextModel) => {
    setProvider(nextProvider);
    setModel(nextModel);
    const p = loadPicker();
    const threads = { ...p.threads };
    if (threadRef.current) threads[threadRef.current] = { provider: nextProvider, model: nextModel };
    savePicker({ provider: nextProvider, models: { ...p.models, [nextProvider]: nextModel }, threads });
  }, []);
  const [draft, setDraft] = useState('');
  const [editing, setEditing] = useState(null);
  const [toast, setToast] = useState(null);
  // Bumped on every change to the selected worktree (History reloads).
  const [historyTick, setHistoryTick] = useState(0);
  // Unresolved merge conflicts in the selected chat's fork.
  const [conflicts, setConflicts] = useState([]);
  const [tab, setTab] = useState('events');
  const [inspectId, setInspectId] = useState(null);
  const [events, setEvents] = useState([]);
  const [files, setFiles] = useState([]);
  const [fileView, setFileView] = useState(null);
  const threadRef = useRef(null);
  threadRef.current = thread;
  const countRef = useRef(0);
  countRef.current = messages.length;

  const fail = useCallback(err => {
    setToast(String(err.message || err));
    setTimeout(() => setToast(null), 5000);
  }, []);

  const refreshState = useCallback(
    () =>
      api.state().then(st => {
        setState(st);
        // Initial loading can fail while the API restarts. Resolve the deep
        // link again on reconnect instead of leaving the saved thread hidden.
        if (!threadRef.current) {
          const want = new URLSearchParams(location.search).get('thread');
          const t = st.threads.find(x => x.id === want);
          if (t) {
            setWorktree(t.worktree);
            setThread(t.id);
          }
        }
      }).catch(fail),
    [fail],
  );
  const refreshPage = useCallback(
    async (reset = false) => {
      const t = threadRef.current;
      if (!t) return;
      try {
        const page = await api.page(t, null, reset ? 40 : Math.max(40, countRef.current + 2));
        if (threadRef.current !== t) return;
        // A live refresh keeps the window's start where it is: pulling older
        // messages in above the reader shifts the list under them mid-turn.
        const first = reset ? -1 : page.messages.findIndex(m => m.id === messagesRef.current[0]?.id);
        setMessages(first > 0 ? page.messages.slice(first) : page.messages);
        if (first <= 0) setHasMore(page.has_more);
        setSessions(page.sessions);
        setPending(p => (p && page.messages.some(m => m.id === p.assistant) ? null : p));
      } catch (e) {
        fail(e);
      }
    },
    [fail],
  );
  // Live file panel: refreshed on every change to the worktree's history
  // (branch switches, agent tool calls, any process writing its files).
  const [flash, setFlash] = useState({});
  const [gone, setGone] = useState([]);
  const prevFiles = useRef(null);
  const worktreeRef = useRef(null);
  worktreeRef.current = worktree;
  const fileViewRef = useRef(null);
  fileViewRef.current = fileView;
  const flashTimer = useRef(null);
  const refreshFiles = useCallback(async () => {
    const wt = worktreeRef.current;
    if (!wt) return;
    const list = await api.files(wt).catch(() => []);
    if (worktreeRef.current !== wt) return;
    const before = prevFiles.current;
    prevFiles.current = list;
    setFiles(list);
    const marks = {};
    const removed = before ? before.filter(f => !list.includes(f)) : [];
    if (before) list.filter(f => !before.includes(f)).forEach(f => (marks[f] = 'added'));
    const fv = fileViewRef.current;
    if (fv) {
      if (!list.includes(fv.path)) setFileView({ ...fv, gone: true });
      else {
        const next = await api.file(wt, fv.path).catch(() => null);
        if (next && (next.text !== fv.text || fv.gone)) {
          if (before) marks[fv.path] = 'changed';
          setFileView(next);
        }
      }
    }
    if (Object.keys(marks).length || removed.length) {
      setFlash(marks);
      setGone(removed);
      clearTimeout(flashTimer.current);
      flashTimer.current = setTimeout(() => {
        setFlash({});
        setGone([]);
      }, 1800);
    }
  }, []);

  useEffect(() => {
    refreshState();
  }, [refreshState]);
  useEffect(() => {
    if (thread) history.replaceState(null, '', `?thread=${thread}`);
  }, [thread]);
  useEffect(() => {
    setMessages([]);
    setLive({});
    liveReasoningRef.current = {};
    setLiveReasoning({});
    setPending(null);
    setInspectId(null);
    setEditing(null);
    refreshPage(true);
  }, [thread, refreshPage]);
  // Opening a thread continues with what was picked in it, else what its
  // last reply used, else the last pick anywhere.
  const pickedFor = useRef(null);
  useEffect(() => {
    if (!thread || pickedFor.current === thread || !state.providers.length) return;
    const saved = loadPicker().threads?.[thread];
    const last = [...messages].reverse().find(m => m.role === 'Assistant' && m.provider);
    if (!saved && !last && !messages.length) return;
    pickedFor.current = thread;
    const usable = id => state.providers.some(p => p.id === id && p.available !== false);
    const choice = saved && usable(saved.provider) ? saved : last && usable(last.provider) ? { provider: last.provider, model: last.model } : null;
    if (choice) {
      setProvider(choice.provider);
      setModel(choice.model || '');
    }
  }, [thread, messages, state.providers]);
  useEffect(() => {
    prevFiles.current = null;
    setFileView(null);
    setFlash({});
    setGone([]);
    refreshFiles();
  }, [worktree, refreshFiles]);

  const loadEvents = useCallback(
    async (id, more = false) => {
      if (!id) return;
      const after = more && events.length ? events[events.length - 1].seq : 0;
      const page = await api.events(id, after, 200).catch(fail);
      if (page) setEvents(prev => (more ? [...prev, ...page] : page));
    },
    [events, fail],
  );

  const refreshConflicts = useCallback(() => {
    const t = threadRef.current;
    if (!t) return setConflicts([]);
    api
      .conflicts(t)
      .then(c => threadRef.current === t && setConflicts(c))
      .catch(() => setConflicts([]));
  }, []);
  useEffect(() => {
    refreshConflicts();
  }, [thread, worktree, refreshConflicts]);

  // Live updates over SSE.
  const timers = useRef({});
  const soon = useCallback((key, fn, ms = 80) => {
    clearTimeout(timers.current[key]);
    timers.current[key] = setTimeout(fn, ms);
  }, []);
  const inspectRef = useRef(null);
  inspectRef.current = inspectId;
  useEffect(() => {
    const es = new EventSource('/api/events');
    es.onopen = () => {
      refreshState();
      refreshPage();
      refreshFiles();
    };
    es.onmessage = ev => {
      const u = JSON.parse(ev.data);
      if (u.type === 'worktree_changed') {
        if (u.worktree === worktreeRef.current) {
          soon('files', refreshFiles, 30);
          soon('history', () => setHistoryTick(n => n + 1), 150);
        }
        return;
      }
      if (u.type === 'synced' || u.type === 'landed') {
        soon('state', refreshState);
        if (u.thread !== threadRef.current) return;
        soon('conflicts', refreshConflicts, 0);
        soon('files', refreshFiles, 30);
        setToast(
          u.type === 'landed'
            ? `Landed ${u.landed} change${u.landed === 1 ? '' : 's'} in the original`
            : u.conflicts.length
              ? `Brought in ${u.brought} change${u.brought === 1 ? '' : 's'}; ${u.conflicts.length} conflict${u.conflicts.length === 1 ? '' : 's'} to resolve`
              : `Up to date: brought in ${u.brought} change${u.brought === 1 ? '' : 's'}`,
        );
        setTimeout(() => setToast(null), 6000);
        return;
      }
      if (u.type === 'thread_moved') {
        soon('state', refreshState);
        if (u.thread !== threadRef.current) return;
        setWorktree(u.to);
        setToast(
          u.forked
            ? `Other chats have worked in this checkout since then, so this chat moved to its own copy at ${u.path}${u.branch ? ` (branch ${u.branch})` : ''}`
            : `This chat moved back to ${u.path}`,
        );
        setTimeout(() => setToast(null), 8000);
        soon('files', refreshFiles, 30);
        return;
      }
      if (u.thread !== threadRef.current) {
        if (u.type === 'turn_ended') soon('state', refreshState);
        return;
      }
      switch (u.type) {
        case 'turn_started':
          soon('page', refreshPage);
          break;
        case 'text_delta':
          setLive(l => ({ ...l, [u.message]: (l[u.message] || '') + u.text }));
          break;
        case 'text':
          setLive(l => (l[u.message] ? l : { ...l, [u.message]: u.text }));
          break;
        case 'reasoning_delta':
        case 'reasoning': {
          const saved = messagesRef.current.find(m => m.id === u.message)?.reasoning;
          const known = mergeReasoning(saved, liveReasoningRef.current[u.message]);
          const blocks = u.type === 'reasoning'
            ? mergeReasoning(known, [u.block])
            : applyReasoningDelta(known, u);
          if (!blocks) {
            soon('page', refreshPage, 0);
            break;
          }
          liveReasoningRef.current = { ...liveReasoningRef.current, [u.message]: blocks };
          setLiveReasoning(liveReasoningRef.current);
          break;
        }
        case 'tool_started':
        case 'tool_finished':
          soon('page', refreshPage);
          soon('files', refreshFiles, 200);
          if (inspectRef.current === u.message) soon('events', () => loadEvents(u.message), 150);
          break;
        case 'git_moved': {
          const at = u.commit.slice(0, 7);
          setToast(
            u.branch
              ? `git: switched to ${u.branch}${u.created ? ' (new branch)' : ''} at ${at}`
              : `git: detached at ${at}`,
          );
          setTimeout(() => setToast(null), 6000);
          soon('files', refreshFiles, 50);
          soon('state', refreshState);
          break;
        }
        case 'turn_ended':
          soon('conflicts', refreshConflicts, 100);
          soon('page', refreshPage, 0);
          soon('state', refreshState);
          soon('files', refreshFiles, 150);
          if (inspectRef.current === u.message) soon('events', () => loadEvents(u.message), 100);
          break;
        default:
      }
    };
    return () => es.close();
  }, [refreshPage, refreshState, refreshFiles, refreshConflicts, loadEvents, soon]);

  const running = messages.some(m => m.status === 'Running') || !!pending;

  const items = useMemo(() => {
    let prev = null;
    const out = messages.map(m => {
      if (m.role === 'User') {
        return { kind: 'user', id: m.id, text: m.text, siblings: m.siblings, siblingIndex: m.sibling_index };
      }
      const streaming = m.status === 'Running';
      const text = streaming ? live[m.id] ?? m.live ?? '' : m.text;
      const reasoning = mergeReasoning(m.reasoning, liveReasoning[m.id]);
      const switchedFrom = m.switched_from || (prev && prev !== m.provider ? prev : null);
      prev = m.provider;
      return {
        kind: 'assistant',
        id: m.id,
        text,
        reasoning,
        streaming,
        pending: streaming && !text && !reasoning.length && m.tools.length === 0,
        tools: m.tools,
        provider: m.provider,
        switchedFrom,
        status: m.status,
        error: m.error,
        inspected: m.id === inspectId,
      };
    });
    if (pending && !messages.some(m => m.id === pending.assistant)) {
      const text = live[pending.assistant] || '';
      const reasoning = liveReasoning[pending.assistant] || [];
      out.push({ kind: 'assistant', id: pending.assistant, text, reasoning, streaming: true, pending: !text && !reasoning.length, tools: [], provider: pending.provider, status: 'Running' });
    }
    return out;
  }, [messages, live, liveReasoning, pending, inspectId]);

  const list = useMugenVirtualizer({ items });

  // Streaming runway: the last exchange always fills the viewport, with the
  // last user message at the top and the reply growing into the space below
  // (so streaming never pushes the page). Mugen measures the bottom slot
  // after the rows on every sync, so this stays exact as text streams.
  const lastUser = useMemo(() => items.map(i => i.kind).lastIndexOf('user'), [items]);
  const COMPOSER_CLEARANCE = 190;
  const runway = () => {
    try {
      const vh = list.viewportHeight;
      if (lastUser < 0 || !vh) return COMPOSER_CLEARANCE;
      const tail = list.offset.total() - list.offset.offsetOf(lastUser);
      return Math.max(COMPOSER_CLEARANCE, Math.round(vh - tail - 8));
    } catch {
      return COMPOSER_CLEARANCE;
    }
  };

  const loadingOlder = useRef(false);
  const loadOlder = useCallback(async () => {
    if (!hasMore || loadingOlder.current || !messages.length) return;
    loadingOlder.current = true;
    try {
      const page = await api.page(thread, messages[0].id, 30);
      setMessages(m => [...page.messages, ...m]);
      setHasMore(page.has_more);
    } catch (e) {
      fail(e);
    } finally {
      loadingOlder.current = false;
    }
  }, [hasMore, messages, thread, fail]);

  const inspect = useCallback(
    (id, which) => {
      setInspectId(id);
      if (which) setTab(which);
      setEvents([]);
      api.events(id, 0, 200).then(setEvents).catch(fail);
    },
    [fail],
  );

  handlers.edit = turn => {
    setEditing(turn);
    setDraft(turn.text);
  };
  // Branch switches keep the switched message where it was on screen: its
  // viewport offset is recorded before the switch and restored for the
  // sibling that replaces it once the new branch has been measured.
  const pin = useRef(null);
  const rowTop = index => list.topSlotHeight + list.offset.offsetOf(index);
  handlers.switchTo = (id, fromId) => {
    const from = items.findIndex(i => i.id === fromId);
    if (from >= 0) pin.current = { id, offset: rowTop(from) - list.scrollTop };
    api
      .switchBranch(id)
      .then(() => refreshPage(true))
      .then(refreshFiles)
      .catch(e => {
        pin.current = null;
        fail(e);
      });
  };
  useLayoutEffect(() => {
    const p = pin.current;
    if (!p) return;
    const index = items.findIndex(i => i.id === p.id);
    if (index < 0) return;
    pin.current = null;
    // After mugen's own sync and scroll anchoring for the new items.
    requestAnimationFrame(() => {
      const el = list.scrollEl;
      if (el) el.scrollTop = Math.max(0, rowTop(index) - p.offset);
    });
  }, [items]);
  handlers.inspect = inspect;

  const submit = async () => {
    const prompt = draft.trim();
    if (!prompt || !thread) return;
    try {
      const turn = editing
        ? await api.edit(editing.id, prompt, provider, model || undefined)
        : await api.send(thread, prompt, provider, model || undefined);
      setPending({ assistant: turn.assistant, provider });
      requestAnimationFrame(() => list.scrollToBottom({ behavior: 'smooth' }));
      setDraft('');
      setEditing(null);
      setInspectId(turn.assistant);
      setEvents([]);
      refreshPage();
      if (editing) refreshFiles();
    } catch (e) {
      fail(e);
    }
  };

  const threadsOf = id => state.threads.filter(t => t.worktree === id);
  const worktreeInfo = state.worktrees.find(w => w.id === worktree);
  const forkInfo = worktreeInfo?.forked_from ? worktreeInfo : null;
  const inspected = messages.find(m => m.id === inspectId);

  return (
    <div className="shell">
      <Sidebar
        state={state}
        worktree={worktree}
        thread={thread}
        threadsOf={threadsOf}
        onWorktree={id => {
          setWorktree(id);
          const first = threadsOf(id)[0];
          setThread(first ? first.id : null);
        }}
        onThread={(wt, id) => {
          setWorktree(wt);
          setThread(id);
        }}
        refresh={refreshState}
        fail={fail}
        onCreatedThread={(wt, t) => {
          setWorktree(wt);
          setThread(t.id);
        }}
      />

      <main className="thread">
        {thread ? (
          <>
            <div className="thread-head">
              <div className="crumb">
                <FolderGit2 size={14} />
                <span>{state.worktrees.find(w => w.id === worktree)?.title}</span>
                <span className="sep">/</span>
                <strong>{state.threads.find(t => t.id === thread)?.title}</strong>
              </div>
              <div className="head-meta">
                <span title="Provider processes alive between turns">{state.warm} warm</span>
              </div>
            </div>
            {forkInfo ? (
              <ForkBar
                fork={forkInfo}
                origin={state.worktrees.find(w => w.id === forkInfo.forked_from?.worktree)}
                conflicts={conflicts}
                onSync={() => api.sync(thread).then(refreshConflicts).catch(fail)}
                onLand={() => api.land(thread).then(refreshConflicts).catch(fail)}
                onResolve={(path, take) => api.resolve(thread, path, take).then(refreshConflicts).catch(fail)}
              />
            ) : null}
            <div className="list-wrap">
              <MugenVList
                instance={list}
                getKey={t => t.id}
                render={TurnRow}
                font="15px Geist, sans-serif"
                lineHeight={26}
                maxW={760}
                overscan={320}
                initialScroll="bottom"
                stickToBottom={running}
                onTopReached={loadOlder}
                renderTop={() =>
                  hasMore ? (
                    <Escape height={56}>
                      <div className="older">scroll up for older messages</div>
                    </Escape>
                  ) : (
                    <VStack height={28} />
                  )
                }
                renderBottom={() => <VStack height={runway()} />}
                className="vlist"
              />
              {items.length === 0 ? <Empty /> : null}
              <Composer
                list={list}
                draft={draft}
                setDraft={setDraft}
                submit={submit}
                running={running}
                stop={() => api.interrupt(thread).catch(fail)}
                providers={state.providers}
                provider={provider}
                model={model}
                pick={pick}
                editing={editing}
                cancelEdit={() => {
                  setEditing(null);
                  setDraft('');
                }}
              />
            </div>
          </>
        ) : (
          <Welcome hasWorktrees={state.worktrees.length > 0} />
        )}
      </main>

      <Inspector
        tab={tab}
        setTab={setTab}
        inspected={inspected}
        events={events}
        loadMore={() => loadEvents(inspectId, true)}
        reload={() => loadEvents(inspectId)}
        files={files}
        flash={flash}
        gone={gone}
        fileView={fileView}
        openFile={p => api.file(worktree, p).then(setFileView).catch(fail)}
        refreshFiles={refreshFiles}
        sessions={sessions}
        worktree={worktreeInfo}
        historyTick={historyTick}
        fail={fail}
      />
      {toast ? (
        <div className="toast" onClick={() => setToast(null)}>
          {toast}
        </div>
      ) : null}
    </div>
  );
}

function Empty() {
  return (
    <div className="empty">
      <p>
        Try the <code>mock</code> provider first: <code>write notes.md hello world</code> writes a file inside a tool call and
        streams a reply.
      </p>
      <p>Then switch provider, edit an earlier message, and flip between branches with ‹ ›.</p>
    </div>
  );
}

function Welcome({ hasWorktrees }) {
  return (
    <div className="welcome">
      <div className="mark">0ndb</div>
      <h1>Worktrees, threads, branches.</h1>
      <p>
        {hasWorktrees
          ? 'Pick a worktree on the left and start a thread.'
          : 'Create a worktree from any local git repository (a fresh ondb/… branch), or adopt a folder.'}
      </p>
    </div>
  );
}

function Sidebar({ state, worktree, thread, threadsOf, onWorktree, onThread, refresh, fail, onCreatedThread }) {
  const [form, setForm] = useState(null);
  const [repo, setRepo] = useState('');
  const [title, setTitle] = useState('');
  const submit = async e => {
    e.preventDefault();
    try {
      if (form === 'new') await api.createWorktree(repo, title || 'playground');
      else if (form === 'adopt') await api.adopt(repo, title || 'folder');
      else if (form === 'thread') {
        const t = await api.createThread(worktree, title || 'New thread');
        await refresh();
        onCreatedThread(worktree, t);
      } else if (form === 'chat') {
        const t = await api.createChat(title || 'New chat');
        await refresh();
        onCreatedThread(t.worktree, t);
      }
      setForm(null);
      setRepo('');
      setTitle('');
      refresh();
    } catch (err) {
      fail(err);
    }
  };
  return (
    <aside className="side">
      <div className="brand">
        <span className="logo">0ndb</span>
        <span className="sub">playground</span>
      </div>
      <div className="side-actions">
        <button onClick={() => setForm(form === 'new' ? null : 'new')}>
          <Plus size={14} /> Worktree
        </button>
        <button onClick={() => setForm(form === 'adopt' ? null : 'adopt')}>
          <FolderPlus size={14} /> Adopt
        </button>
        <button onClick={() => setForm(form === 'chat' ? null : 'chat')} title="A chat with a scratch folder of its own">
          <MessageCircle size={14} /> Chat
        </button>
      </div>
      {form ? (
        <form className="side-form" onSubmit={submit}>
          {form !== 'thread' && form !== 'chat' ? (
            <input
              autoFocus
              placeholder={form === 'new' ? '/path/to/git/repo' : '/path/to/folder'}
              value={repo}
              onChange={e => setRepo(e.target.value)}
            />
          ) : null}
          <input autoFocus={form === 'thread' || form === 'chat'} placeholder="title" value={title} onChange={e => setTitle(e.target.value)} />
          <div className="row">
            <button type="submit" className="primary">
              {form === 'new' ? 'Create worktree' : form === 'adopt' ? 'Adopt folder' : form === 'chat' ? 'Start chat' : 'Create thread'}
            </button>
            <button type="button" onClick={() => setForm(null)}>
              Cancel
            </button>
          </div>
        </form>
      ) : null}
      <div className="tree">
        {state.worktrees.map(w => (
          <div key={w.id} className={`wt ${w.id === worktree ? 'on' : ''}`}>
            <div className="wt-head" onClick={() => onWorktree(w.id)}>
              <FolderGit2 size={14} />
              <div className="wt-text">
                <span className="wt-title">{w.title}</span>
                <span className="wt-branch">{w.branch || w.path.split('/').slice(-1)[0]}</span>
              </div>
              <button
                className="icon"
                title="Remove worktree"
                onClick={e => {
                  e.stopPropagation();
                  if (confirm(`Remove ${w.title}?${w.created ? ' This deletes the worktree and its branch.' : ''}`))
                    api.removeWorktree(w.id, true).then(refresh).catch(fail);
                }}
              >
                <Trash2 size={13} />
              </button>
            </div>
            {w.id === worktree ? (
              <div className="threads">
                {threadsOf(w.id).map(t => (
                  <div key={t.id} className={`th ${t.id === thread ? 'on' : ''}`} onClick={() => onThread(w.id, t.id)}>
                    {t.title}
                  </div>
                ))}
                <div className="th new" onClick={() => setForm('thread')}>
                  <MessageSquarePlus size={13} /> New thread
                </div>
              </div>
            ) : null}
          </div>
        ))}
      </div>
    </aside>
  );
}

function ScrollToBottom({ list }) {
  const away = useMugenSelector(list, s => s.distanceFromBottom > 200);
  return (
    <button className="to-bottom" data-hidden={!away} onClick={() => list.scrollToBottom({ behavior: 'smooth' })}>
      <ArrowDown size={12} /> Scroll to bottom
    </button>
  );
}

function Composer(props) {
  const { list, draft, setDraft, submit, running, stop, providers, provider, model, pick, editing, cancelEdit } = props;
  return (
    <div className="composer-dock">
      <ScrollToBottom list={list} />
      <div className={`composer ${editing ? 'editing' : ''}`}>
        {editing ? (
          <div className="edit-bar">
            <span>Editing a message: a new branch from there, with the files as they were then.</span>
            <button className="icon" onClick={cancelEdit} title="Cancel edit">
              <X size={14} />
            </button>
          </div>
        ) : null}
        <textarea
          rows={2}
          placeholder={running ? 'The agent is working…' : 'Message the agent (Enter to send)'}
          value={draft}
          onChange={e => setDraft(e.target.value)}
          onKeyDown={e => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault();
              if (!running) submit();
            }
          }}
        />
        <div className="composer-bar">
          <ModelPicker providers={providers} provider={provider} model={model} onChange={pick} />
          <div className="grow" />
          {running ? (
            <button className="send stop" onClick={stop} title="Stop">
              <Square size={13} fill="currentColor" />
            </button>
          ) : (
            <button className="send" onClick={submit} disabled={!draft.trim()} title="Send">
              <ArrowUp size={16} />
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function Inspector({ tab, setTab, inspected, events, loadMore, reload, files, flash, gone, fileView, openFile, refreshFiles, sessions, worktree, historyTick, fail }) {
  return (
    <aside className="inspector">
      <div className="tabs">
        {['events', 'tools', 'files', 'history', 'sessions'].map(t => (
          <button key={t} className={tab === t ? 'on' : ''} onClick={() => setTab(t)}>
            {t}
          </button>
        ))}
      </div>
      <div className="pane">
        {tab === 'events' ? (
          inspected ? (
            <>
              <div className="pane-head">
                <span>
                  {events.length} event{events.length === 1 ? '' : 's'} · {inspected.provider}
                </span>
                <button className="icon" onClick={reload} title="Reload">
                  <RefreshCw size={13} />
                </button>
              </div>
              {events.map(ev => (
                <EventRow key={ev.seq} ev={ev} />
              ))}
              {events.length && events.length % 200 === 0 ? (
                <button className="more" onClick={loadMore}>
                  Load more
                </button>
              ) : null}
            </>
          ) : (
            <Hint>Click “Events” under an agent reply to see its raw provider events.</Hint>
          )
        ) : null}
        {tab === 'tools' ? (
          inspected && inspected.tools.length ? (
            inspected.tools.map(t => <ToolDetail key={t.id} tool={t} />)
          ) : (
            <Hint>Tool calls of the selected reply appear here, with output and their attribution scope.</Hint>
          )
        ) : null}
        {tab === 'history' ? <HistoryPane worktree={worktree} tick={historyTick} fail={fail} /> : null}
        {tab === 'files' ? (
          <>
            <div className="pane-head">
              <span>
                <span className="live-dot" title="Updates live" /> {worktree ? worktree.path.split('/').slice(-2).join('/') : 'no worktree'}
              </span>
              <button className="icon" onClick={refreshFiles} title="Reload">
                <RefreshCw size={13} />
              </button>
            </div>
            {[...files, ...gone.filter(g => !files.includes(g))].sort().map(f => {
              const removed = gone.includes(f) && !files.includes(f);
              return (
                <div
                  key={f}
                  className={`file ${fileView?.path === f ? 'on' : ''} ${flash[f] || ''} ${removed ? 'removed' : ''}`}
                  onClick={() => !removed && openFile(f)}
                >
                  {f}
                </div>
              );
            })}
            {fileView ? (
              <pre key={fileView.path} className={`file-view ${flash[fileView.path] === 'changed' ? 'flash' : ''} ${fileView.gone ? 'gone' : ''}`}>
                <div className="file-name">
                  {fileView.path}
                  {fileView.gone ? ' (not on this branch)' : ''}
                </div>
                {fileView.text}
              </pre>
            ) : null}
          </>
        ) : null}
        {tab === 'sessions' ? (
          sessions.length ? (
            sessions.map(s => (
              <div key={s.id} className="session">
                <div>
                  <span className="chip">{s.provider}</span> <code>{s.id}</code>
                </div>
                <div className="kv">native {s.native || '…'}</div>
                {s.forked_from ? <div className="kv">forked from {s.forked_from}</div> : null}
                <div className="kv">seen up to {s.seen || '—'}</div>
              </div>
            ))
          ) : (
            <Hint>Provider sessions of this thread: continued, forked at a message, or fresh.</Hint>
          )
        ) : null}
      </div>
    </aside>
  );
}

function Hint({ children }) {
  return <div className="hint">{children}</div>;
}

function EventRow({ ev }) {
  const [open, setOpen] = useState(false);
  let pretty = ev.raw || '';
  if (open && ev.raw) {
    try {
      pretty = JSON.stringify(JSON.parse(ev.raw), null, 2);
    } catch {
      /* not JSON (stderr) */
    }
  }
  return (
    <div className={`event ${open ? 'open' : ''}`} onClick={() => setOpen(!open)}>
      <div className="event-head">
        <span className="seq">{ev.seq}</span>
        <span className={`kind k-${ev.kind.split('/')[0]}`}>{ev.kind}</span>
      </div>
      <pre>{pretty}</pre>
    </div>
  );
}

function ToolDetail({ tool }) {
  const view = presentTool(tool);
  return (
    <div className={`tool-inspector ${tool.is_error ? 'err' : ''}`}>
      <div className="td-head">
        <strong>{tool.name}</strong>
        <span className={`tc-result tc-${view.status}`}>{view.status} {view.duration}</span>
      </div>
      <div className="td-label">input</div>
      <pre>{JSON.stringify(view.input, null, 2)}</pre>
      {view.sections.map((section, i) => (
        <section key={i} className={section.error ? 'td-error' : ''}>
          <div className="td-label">{section.label}</div>
          <pre>{section.text}</pre>
        </section>
      ))}
      {!view.sections.length ? <div className="td-label">No recorded output</div> : null}
      {tool.scope ? <div className="td-scope">scope <code>{tool.scope}</code></div> : null}
    </div>
  );
}
