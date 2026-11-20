import { useCallback, useEffect, useMemo, useState } from 'react';
import { ChevronRight, GitCommitHorizontal, GitMerge, HardDrive, RotateCcw, Sparkles } from 'lucide-react';
import { api } from './api.js';
import './history.css';

// The worktree's history from 0ndb's timeline: every change, newest first,
// grouped by the turn that made it, with diffs from just before to just
// after (what happened then, whatever came later).

const PATCH_LINES = 400;

function ago(ms) {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return new Date(ms).toLocaleDateString();
}

/** Who made a change, in words. */
function origin(entry) {
  if (entry.git) return { icon: GitCommitHorizontal, label: 'Git wrote files', who: 'git' };
  if (entry.actor === 'restore') return { icon: RotateCcw, label: 'Restored an earlier message', who: 'restore' };
  if (entry.actor === 'land') return { icon: GitMerge, label: 'Merged from another chat', who: 'merge' };
  if (entry.actor_kind === 'Ingestion') return { icon: HardDrive, label: 'Edited on disk', who: 'you or another program' };
  return { icon: Sparkles, label: entry.turn?.label || entry.scope?.label || 'Agent change', who: entry.actor };
}

/** Consecutive entries from the same turn (or the same kind of outside edit) form one group. */
function group(entries) {
  const out = [];
  for (const e of entries) {
    const key = e.turn ? `turn:${e.turn.id}` : `${origin(e).who}`;
    const last = out[out.length - 1];
    if (last && last.key === key) last.entries.push(e);
    else out.push({ key, entries: [e] });
  }
  return out;
}

function totals(entries) {
  const files = new Set();
  let added = 0;
  let removed = 0;
  let more = 0;
  for (const e of entries) {
    for (const f of e.files) {
      files.add(f.path);
      added += f.added;
      removed += f.removed;
    }
    more += e.more_files;
  }
  return { files: files.size + more, added, removed };
}

function Stat({ added, removed }) {
  return (
    <span className="hx-stat">
      {added ? <span className="hx-add">+{added}</span> : null}
      {removed ? <span className="hx-del">−{removed}</span> : null}
    </span>
  );
}

function Patch({ text }) {
  const [all, setAll] = useState(false);
  const lines = text.split('\n').filter(l => !l.startsWith('--- ') && !l.startsWith('+++ '));
  const shown = all ? lines : lines.slice(0, PATCH_LINES);
  return (
    <pre className="hx-patch">
      {shown.map((l, i) => (
        <div key={i} className={l.startsWith('@@') ? 'hx-hunk' : l.startsWith('+') ? 'hx-l-add' : l.startsWith('-') ? 'hx-l-del' : ''}>
          {l || ' '}
        </div>
      ))}
      {lines.length > shown.length ? (
        <button className="hx-more" onClick={() => setAll(true)}>
          Show {lines.length - shown.length} more lines
        </button>
      ) : null}
    </pre>
  );
}

function FileDiff({ file }) {
  const [open, setOpen] = useState(true);
  const label = { added: 'added', removed: 'deleted', moved: `moved from ${file.from}`, modified: '' }[file.status];
  return (
    <div className="hx-file">
      <button className="hx-file-head" onClick={() => setOpen(o => !o)} aria-expanded={open}>
        <ChevronRight size={12} className={open ? 'hx-open' : ''} />
        <span className="hx-path">{file.path}</span>
        {label ? <span className="hx-tag">{label}</span> : null}
        <Stat added={file.added} removed={file.removed} />
      </button>
      {open ? (
        file.binary ? (
          <div className="hx-note">Binary file changed.</div>
        ) : file.patch ? (
          <Patch text={file.patch} />
        ) : (
          <div className="hx-note">{file.status === 'removed' ? 'File deleted.' : 'Diff too large to show.'}</div>
        )
      ) : null}
    </div>
  );
}

function Group({ worktree, group: g, open, toggle, fail }) {
  const head = g.entries[0];
  const o = origin(head);
  const Icon = o.icon;
  const t = totals(g.entries);
  const [diff, setDiff] = useState(null);
  const ids = g.entries.map(e => e.id).join(',');
  useEffect(() => {
    if (!open) return;
    let alive = true;
    api
      .diff(worktree, ids)
      .then(d => alive && setDiff(d))
      .catch(fail);
    return () => {
      alive = false;
    };
  }, [open, worktree, ids, fail]);
  const tools = g.entries.filter(e => e.scope && e.scope.kind !== 'Turn');
  return (
    <li className={`hx-group ${open ? 'hx-expanded' : ''}`}>
      <button className="hx-head" onClick={toggle} aria-expanded={open}>
        <Icon size={14} className="hx-icon" />
        <span className="hx-title" title={o.label}>
          {o.label}
        </span>
        <span className="hx-meta">
          {t.files} file{t.files === 1 ? '' : 's'} <Stat added={t.added} removed={t.removed} />
        </span>
      </button>
      <div className="hx-sub">
        {o.who} · {ago(head.wall_ms)}
        {g.entries.some(e => e.pruned) ? ' · details pruned' : ''}
      </div>
      {open ? (
        <div className="hx-body">
          {tools.length ? (
            <ul className="hx-steps">
              {tools.map(e => (
                <li key={e.id}>
                  <span className="hx-step-label">{e.scope.label}</span>
                  <Stat {...totals([e])} />
                </li>
              ))}
            </ul>
          ) : null}
          {diff ? diff.map(f => <FileDiff key={f.path} file={f} />) : <div className="hx-note">Loading changes…</div>}
        </div>
      ) : null}
    </li>
  );
}

export default function HistoryPane({ worktree, tick, fail }) {
  const [entries, setEntries] = useState([]);
  const [hasMore, setHasMore] = useState(false);
  const [open, setOpen] = useState({});
  const load = useCallback(
    async (before = null) => {
      if (!worktree) return;
      try {
        const page = await api.history(worktree.id, before);
        setEntries(prev => (before ? [...prev, ...page.entries] : page.entries));
        setHasMore(page.has_more);
      } catch (e) {
        fail(e);
      }
    },
    [worktree, fail],
  );
  // Reload on every change to the worktree; keep what's expanded.
  useEffect(() => {
    load();
  }, [load, tick]);
  const groups = useMemo(() => group(entries), [entries]);
  if (!worktree) return <div className="hint">Pick a worktree to see its history.</div>;
  return (
    <div className="hx">
      <div className="pane-head">
        <span>
          {worktree.title}
          {worktree.forked_from ? ' · fork' : ''}
        </span>
      </div>
      {groups.length === 0 ? <div className="hint">No changes yet. Everything an agent, a person or git does here shows up as it happens.</div> : null}
      <ul className="hx-list">
        {groups.map(g => (
          <Group
            key={g.entries[0].id}
            worktree={worktree.id}
            group={g}
            open={!!open[g.entries[0].id]}
            toggle={() => setOpen(o => ({ ...o, [g.entries[0].id]: !o[g.entries[0].id] }))}
            fail={fail}
          />
        ))}
      </ul>
      {hasMore ? (
        <button className="more" onClick={() => load(entries[entries.length - 1]?.id)}>
          Load older changes
        </button>
      ) : null}
    </div>
  );
}
