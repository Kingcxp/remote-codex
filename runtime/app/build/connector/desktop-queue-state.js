export function desktopQueueState(state, previousTurnId) {
    const turns = [...(state.turns || []), ...Object.values(state.turnHistory?.history?.entitiesByKey || {})];
    return {
        ready: state.threadRuntimeStatus?.type === 'idle' && !state.requests?.length
            && !state.unconfirmedTurnSubmissions?.length && state.threadGoal?.status !== 'active'
            && !turns.some(t => t.status === 'inProgress'),
        previousTurnComplete: !previousTurnId || turns.some(t => t.turnId === previousTurnId
            && ['completed', 'interrupted', 'failed'].includes(t.status)),
    };
}
