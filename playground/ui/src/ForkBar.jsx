import { useState } from 'react';
import { GitFork, GitMerge, RefreshCw, TriangleAlert } from 'lucide-react';
import './history.css';

const KIND = {
  text: 'both edited the same lines (conflict markers are in your copy)',
  binary: 'both changed this binary file (your version is on disk)',
  deleted_here: 'you deleted it, the other side edited it (their edit is back)',
  deleted_there: 'the other side deleted it, you edited it (your edit is kept)',
};

export default function ForkBar({ fork, origin, conflicts, onSync, onLand, onResolve }) {
  const [busy, setBusy] = useState(null);
  const run = (what, fn) => async () => {
    setBusy(what);
    try {
      await fn();
    } finally {
      setBusy(null);
    }
  };
  const shared = fork.forked_from?.shared;
  return (
    <div className="fork-bar">
      <div className="fork-main">
        <GitFork size={14} className="fork-icon" />
        <div className="fork-text">
          <strong>Working in its own copy</strong>
          <span>
            forked from {origin?.title || 'another worktree'}
            {fork.branch ? <> · <code>{fork.branch}</code></> : null}
          </span>
        </div>
        {shared ? (
          <div className="fork-actions">
            <button onClick={run('sync', onSync)} disabled={!!busy} title={`Bring in what changed in ${origin?.title || 'the original'} since`}>
              <RefreshCw size={13} className={busy === 'sync' ? 'spin' : ''} /> Sync
            </button>
            <button className="primary" onClick={run('land', onLand)} disabled={!!busy || conflicts.length > 0} title={`Apply this chat's changes to ${origin?.title || 'the original'}`}>
              <GitMerge size={13} /> Land
            </button>
          </div>
        ) : (
          <span className="fork-note">Its history was started fresh, so it can't be landed; merge its branch with git.</span>
        )}
      </div>
      {conflicts.length ? (
        <div className="fork-conflicts">
          <div className="fork-conflicts-head">
            <TriangleAlert size={13} /> {conflicts.length} conflict{conflicts.length === 1 ? '' : 's'} to resolve before landing
          </div>
          <ul>
            {conflicts.map(c => (
              <li key={c.path}>
                <code className="fork-path">{c.path}</code>
                <span className="fork-kind">{KIND[c.kind] || c.kind}</span>
                <span className="grow" />
                <button onClick={run(`ours:${c.path}`, () => onResolve(c.path, 'ours'))} disabled={!!busy}>
                  Keep mine
                </button>
                <button onClick={run(`theirs:${c.path}`, () => onResolve(c.path, 'theirs'))} disabled={!!busy}>
                  Take theirs
                </button>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}
