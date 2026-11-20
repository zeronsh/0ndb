async function call(method, path, body) {
  const res = await fetch(`/api${path}`, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
  // Only HTTP failures are errors: messages themselves carry an `error` field.
  if (!res.ok) throw new Error((json && json.error) || `HTTP ${res.status}`);
  return json;
}

export const api = {
  state: () => call('GET', '/state'),
  createWorktree: (repo, title, base) => call('POST', '/worktrees', { repo, title, base }),
  adopt: (path, title) => call('POST', '/worktrees/adopt', { path, title }),
  removeWorktree: (id, force) => call('POST', `/worktrees/${id}/remove`, { force, delete_branch: true }),
  files: id => call('GET', `/worktrees/${id}/files`),
  file: (id, path) => call('GET', `/worktrees/${id}/file?path=${encodeURIComponent(path)}`),
  models: (provider, refresh) => call('GET', `/providers/${provider}/models${refresh ? '?refresh=1' : ''}`),
  pr: id => call('GET', `/worktrees/${id}/pr`),
  createThread: (worktree, title) => call('POST', '/threads', { worktree, title }),
  page: (thread, before, limit = 40) =>
    call('GET', `/threads/${thread}/page?limit=${limit}${before ? `&before=${before}` : ''}`),
  send: (thread, prompt, provider, model) => call('POST', `/threads/${thread}/send`, { prompt, provider, model }),
  interrupt: thread => call('POST', `/threads/${thread}/interrupt`),
  edit: (message, prompt, provider, model) => call('POST', `/messages/${message}/edit`, { prompt, provider, model }),
  switchBranch: message => call('POST', `/messages/${message}/switch`),
  events: (message, after = 0, limit = 100) => call('GET', `/messages/${message}/events?after=${after}&limit=${limit}`),
  history: (worktree, before, limit = 40) =>
    call('GET', `/worktrees/${worktree}/history?limit=${limit}${before ? `&before=${encodeURIComponent(before)}` : ''}`),
  diff: (worktree, ids) => call('GET', `/worktrees/${worktree}/diff?ids=${encodeURIComponent(ids)}`),
  createChat: title => call('POST', '/chats', { title }),
  sync: thread => call('POST', `/threads/${thread}/sync`),
  land: thread => call('POST', `/threads/${thread}/land`),
  conflicts: thread => call('GET', `/threads/${thread}/conflicts`),
  resolve: (thread, path, take, content) => call('POST', `/threads/${thread}/resolve`, { path, take, content }),
};
