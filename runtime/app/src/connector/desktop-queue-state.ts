export function desktopQueueState(state: Record<string, any>, previousTurnId?: string) {
  const turns = [...(state.turns || []), ...Object.values(state.turnHistory?.history?.entitiesByKey || {})] as Record<string, any>[];
  return {
    ready: state.threadRuntimeStatus?.type === 'idle' && !state.requests?.length
      && !state.unconfirmedTurnSubmissions?.length && state.threadGoal?.status !== 'active'
      && !turns.some(t => t.status === 'inProgress'),
    previousTurnComplete: !previousTurnId || turns.some(t => t.turnId === previousTurnId
      && ['completed', 'interrupted', 'failed'].includes(t.status)),
  };
}
