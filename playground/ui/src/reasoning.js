// Page loads and streaming updates can race; a newer revision always wins.
export function mergeReasoning(saved = [], live = []) {
  const blocks = new Map(saved.map(block => [block.id, block]));
  for (const block of live) {
    if ((blocks.get(block.id)?.revision ?? -1) < block.revision) blocks.set(block.id, block);
  }
  return [...blocks.values()].sort((a, b) => a.id - b.id);
}

// null means a delta was missed: fetch a fresh page instead of displaying a
// truncated trace. Completed-block snapshots can bridge any revision gap.
export function applyReasoningDelta(blocks, event) {
  const current = blocks.find(block => block.id === event.block);
  if ((current?.revision ?? 0) >= event.revision) return blocks;
  if ((current?.revision ?? 0) + 1 !== event.revision) return null;
  return mergeReasoning(blocks, [{
    id: event.block,
    text: (current?.text ?? '') + event.text,
    started_ms: event.started_ms,
    ended_ms: null,
    revision: event.revision,
  }]);
}
