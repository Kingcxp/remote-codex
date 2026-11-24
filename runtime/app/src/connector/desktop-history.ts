import { extractText, mapTurns } from './app-server-history.js';
import { summarizeToolActivity } from '../shared/activity-detail.js';

type Value = Record<string, any>;

// Read only the selected turn's visible items. Never forward raw Desktop state,
// provider settings, tool outputs, or encrypted/private reasoning content.
export function desktopHistorySnapshot(state: Value) {
  const runtime = String(state.threadRuntimeStatus?.type || 'unknown');
  if (!['active', 'idle'].includes(runtime)) return null;
  const turns = new Map<string, Value>();
  for (const turn of [...Object.values(state.turnHistory?.history?.entitiesByKey || {}), ...(state.turns || [])] as Value[]) {
    if (turn?.turnId) turns.set(turn.turnId, turn);
  }
  const turn = [...turns.values()].filter(t => runtime !== 'active' || t.status === 'inProgress')
    .sort((a, b) => (b.turnStartedAtMs || 0) - (a.turnStartedAtMs || 0))[0];
  if (!turn) return null;
  const active = runtime === 'active';
  const rawItems = Array.isArray(turn.items) ? turn.items : [];
  const inputId = turn.params?.clientUserMessageId || `desktop-input:${turn.turnId}`;
  const items: Value[] = rawItems.map((item: Value) => ({ ...item,
    ...(item.type === 'plan' ? { status: !active || turn.completedItemIds?.includes(item.id)
      || item.completedAtMs ? 'completed' : 'inProgress' } : {}),
    ...(item.type === 'reasoning' ? { content: [], encrypted_content: undefined } : {}),
    ...(item.type === 'userMessage' && item.clientId === inputId ? { id: inputId } : {}),
    completedAt: item.completedAtMs || item.startedAtMs || null,
  }));
  // Pre-turn compaction happens before Codex writes the user message to disk.
  // Its accepted input already exists in the owning Desktop turn parameters.
  const acceptedText = extractText({ input: turn.params?.input });
  const acceptedInputExists = rawItems.some((item: Value) => item.type === 'userMessage'
    && (item.clientId ? item.clientId === inputId : item.id === inputId || extractText(item) === acceptedText));
  if (!acceptedInputExists && Array.isArray(turn.params?.input)) {
    items.unshift({ id: inputId, type: 'userMessage', content: turn.params.input, completedAt: turn.turnStartedAtMs });
  }
  const mapped = mapTurns([{ id: turn.turnId, status: active ? 'inProgress' : turn.status,
    startedAt: turn.turnStartedAtMs, completedAt: active ? null : turn.completedAtMs || null, items }])[0];
  const compacting = active ? [...rawItems].reverse().find((item: Value) => item.type === 'contextCompaction'
    && !item.completed && !item.completedAtMs) : undefined;
  const latest = rawItems.at(-1);
  const waiting = active && Boolean(state.requests?.length);
  const kind = !active ? '' : waiting ? 'waiting' : compacting ? 'compacting'
    : latest?.type === 'plan' ? 'writingPlan'
    : latest?.type === 'reasoning' ? 'planning'
      : latest?.type === 'agentMessage' ? 'responding'
        : /commandExecution/i.test(latest?.type || '') ? 'command'
          : /fileChange/i.test(latest?.type || '') ? 'editing'
            : /webSearch/i.test(latest?.type || '') ? 'searching'
              : /mcpTool|toolCall/i.test(latest?.type || '') ? 'connectedTool'
                : rawItems.some((item: Value) => item.type === 'contextCompaction' && item.completed) ? 'working' : 'starting';
  const activityUpdatedAt = Math.max(turn.turnStartedAtMs || 0,
    ...rawItems.map((item: Value) => item.completedAtMs || item.startedAtMs || 0));
  return { threadId: state.id, turn: mapped, activityId: turn.turnId,
    activityKind: kind, activityStartedAt: active ? turn.turnStartedAtMs || null : null,
    activityUpdatedAt: active ? activityUpdatedAt || null : null,
    activityDetail: !waiting && active && latest ? summarizeToolActivity(latest) : '',
    compactionStartedAt: compacting?.startedAtMs || null };
}

export function mergeDesktopHistoryPage(page: Value, snapshot: ReturnType<typeof desktopHistorySnapshot>) {
  if (!snapshot || page.threadId !== snapshot.threadId) return page;
  const id = snapshot.activityId;
  const toMillis = (value: number) => value < 10_000_000_000 ? value * 1000 : value;
  const latest = page.turns?.[0];
  const diskStart = page.activityStartedAt || latest?.startedAt;
  if (diskStart && toMillis(diskStart) > snapshot.turn.startedAt) return page;
  // Completed persisted output wins over a delayed owner patch for that turn.
  // An interrupted placeholder with no completion timestamp is not such evidence.
  if (latest?.id === id && /^(completed|failed)$/.test(latest.status) && latest.completedAt
    && snapshot.turn.status === 'inProgress') return page;
  const turns = (page.turns || []).flatMap((turn: Value) => {
    if (turn.id === id) return [];
    const items = (turn.items || []).filter((item: Value) => item.turnId !== id);
    return items.length || !turn.items?.length && !/^(tail|rollout):/.test(turn.id) ? [{ ...turn, items }] : [];
  });
  return { ...page, turns: [snapshot.turn, ...turns], source: 'desktop',
    activityId: id, activityKind: snapshot.activityKind,
    activityStartedAt: snapshot.activityStartedAt, activityUpdatedAt: snapshot.activityUpdatedAt,
    compactionStartedAt: snapshot.compactionStartedAt, activityDetail: snapshot.activityDetail,
    toolPurpose: '',
  };
}
