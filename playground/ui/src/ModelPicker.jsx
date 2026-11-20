import { useEffect, useMemo, useRef, useState } from 'react';
import { Check, ChevronDown, RefreshCw, Search } from 'lucide-react';
import { api } from './api.js';

const catalogs = new Map();
const listeners = new Set();

function loadModels(provider, refresh = false) {
  const have = catalogs.get(provider);
  if (have && !refresh && have.status !== 'error') return;
  catalogs.set(provider, { status: 'loading', models: have?.models || [] });
  listeners.forEach(l => l());
  api
    .models(provider, refresh)
    .then(models => catalogs.set(provider, { status: 'ready', models }))
    .catch(err => catalogs.set(provider, { status: 'error', models: [], error: String(err.message || err) }))
    .finally(() => listeners.forEach(l => l()));
}

function useCatalog(provider) {
  const [, bump] = useState(0);
  useEffect(() => {
    const l = () => bump(x => x + 1);
    listeners.add(l);
    return () => listeners.delete(l);
  }, []);
  return provider ? catalogs.get(provider) : null;
}

export function modelLabel(provider, model) {
  if (!model) return 'Default';
  return catalogs.get(provider)?.models.find(m => m.id === model)?.name || model;
}

export function ModelPicker({ providers, provider, model, onChange, disabled }) {
  const [open, setOpen] = useState(false);
  const [focus, setFocus] = useState(provider);
  const [query, setQuery] = useState('');
  const [cursor, setCursor] = useState(0);
  const root = useRef(null);
  const search = useRef(null);
  const listRef = useRef(null);
  const catalog = useCatalog(focus);
  useCatalog(provider);

  useEffect(() => {
    if (provider) loadModels(provider);
  }, [provider]);

  useEffect(() => {
    if (!open) return;
    setFocus(provider);
    setQuery('');
    const close = e => root.current && !root.current.contains(e.target) && setOpen(false);
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);

  const focused = providers.find(p => p.id === focus);
  useEffect(() => {
    if (open && focused?.available) loadModels(focus);
    setCursor(0);
    search.current?.focus();
  }, [open, focus]);

  const options = useMemo(() => {
    const models = catalog?.models || [];
    const defaultName = models.find(m => m.default)?.name;
    const all = [{ id: '', name: 'Default', hint: defaultName }, ...models.map(m => ({ ...m, hint: m.default ? 'default' : null }))];
    const q = query.trim().toLowerCase();
    if (!q) return all;
    return all.filter(m => m.name.toLowerCase().includes(q) || m.id.toLowerCase().includes(q));
  }, [catalog, query]);

  useEffect(() => {
    listRef.current?.querySelector('[data-cursor="true"]')?.scrollIntoView({ block: 'nearest' });
  }, [cursor]);

  const choose = m => {
    onChange(focus, m.id);
    setOpen(false);
  };

  const onKey = e => {
    if (e.key === 'Escape') setOpen(false);
    else if (e.key === 'ArrowDown') {
      e.preventDefault();
      setCursor(c => Math.min(options.length - 1, c + 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setCursor(c => Math.max(0, c - 1));
    } else if (e.key === 'Enter' && options[cursor] && focused?.available) {
      e.preventDefault();
      choose(options[cursor]);
    } else if (e.key === 'Tab') {
      e.preventDefault();
      const usable = providers.filter(p => p.available);
      const i = usable.findIndex(p => p.id === focus);
      const next = usable[(i + (e.shiftKey ? usable.length - 1 : 1)) % usable.length];
      if (next) setFocus(next.id);
    }
  };

  const current = providers.find(p => p.id === provider);
  return (
    <div className="picker" ref={root}>
      <button className="picker-button" onClick={() => setOpen(o => !o)} disabled={disabled} title="Provider and model">
        <span className="picker-provider">{current?.name || provider}</span>
        <span className="picker-model">{modelLabel(provider, model)}</span>
        <ChevronDown size={13} />
      </button>
      {open ? (
        <div className="picker-pop" onKeyDown={onKey}>
          <div className="picker-providers">
            {providers.map(p => (
              <button
                key={p.id}
                className={`picker-prov ${p.id === focus ? 'on' : ''} ${p.available ? '' : 'missing'}`}
                onMouseEnter={() => p.available && setFocus(p.id)}
                onClick={() => setFocus(p.id)}
                title={p.available ? p.id : `${p.name} isn't installed`}
              >
                <span>{p.name}</span>
                {p.id === provider ? <Check size={12} /> : !p.available ? <small>not installed</small> : null}
              </button>
            ))}
          </div>
          <div className="picker-models">
            <div className="picker-search">
              <Search size={13} />
              <input
                ref={search}
                placeholder={`Search ${focused?.name || ''} models`}
                value={query}
                onChange={e => {
                  setQuery(e.target.value);
                  setCursor(0);
                }}
              />
              <button
                className="icon"
                title="Ask the provider again"
                onClick={() => loadModels(focus, true)}
                disabled={!focused?.available}
              >
                <RefreshCw size={12} className={catalog?.status === 'loading' ? 'spin' : ''} />
              </button>
            </div>
            <div className="picker-list" ref={listRef}>
              {!focused?.available ? (
                <div className="picker-note">{focused?.name} isn't installed on this machine.</div>
              ) : catalog?.status === 'error' ? (
                <div className="picker-note error">{catalog.error}</div>
              ) : (
                <>
                  {options.map((m, i) => (
                    <button
                      key={m.id || 'default'}
                      data-cursor={i === cursor}
                      className={`picker-opt ${i === cursor ? 'cursor' : ''}`}
                      onMouseMove={() => setCursor(i)}
                      onClick={() => choose(m)}
                      title={m.id || "The provider's own default"}
                    >
                      <span className="picker-name">{m.name}</span>
                      {m.hint ? <small>{m.hint}</small> : null}
                      {focus === provider && m.id === (model || '') ? <Check size={12} /> : null}
                    </button>
                  ))}
                  {catalog?.status === 'loading' ? <div className="picker-note">Asking {focused.name} for its models…</div> : null}
                  {catalog?.status === 'ready' && options.length === 0 ? (
                    <div className="picker-note">No models match “{query}”.</div>
                  ) : null}
                </>
              )}
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
