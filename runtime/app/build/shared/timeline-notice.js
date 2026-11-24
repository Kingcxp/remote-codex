const TEXT_LIMIT = 500;
export function normalizeTimelineNotice(value) {
    if (!value || typeof value !== 'object')
        return undefined;
    const candidate = value;
    if (candidate.kind === 'turnStatus') {
        const status = String(candidate.status || '');
        if (!['failed', 'aborted', 'error'].includes(status))
            return undefined;
        const detail = boundedText(candidate.detail);
        return {
            kind: 'turnStatus',
            status: status,
            ...(detail ? { detail } : {}),
        };
    }
    if (candidate.kind === 'modelSettings') {
        const model = boundedText(candidate.model);
        const reasoningEffort = boundedText(candidate.reasoningEffort);
        const serviceTier = boundedText(candidate.serviceTier);
        if (!model && !reasoningEffort && !serviceTier)
            return undefined;
        return {
            kind: 'modelSettings',
            ...(model ? { model } : {}),
            ...(reasoningEffort ? { reasoningEffort } : {}),
            ...(serviceTier ? { serviceTier } : {}),
        };
    }
    if (candidate.kind === 'approval') {
        const decision = String(candidate.decision || '');
        if (decision !== 'approved' && decision !== 'rejected')
            return undefined;
        const approvalKind = boundedText(candidate.approvalKind);
        const summary = boundedText(candidate.summary);
        return {
            kind: 'approval',
            decision,
            ...(approvalKind ? { approvalKind } : {}),
            ...(summary ? { summary } : {}),
        };
    }
    if (candidate.kind === 'toolSummary') {
        const counts = {
            commands: nonNegativeInteger(candidate.commands),
            edits: nonNegativeInteger(candidate.edits),
            searches: nonNegativeInteger(candidate.searches),
            connectedTools: nonNegativeInteger(candidate.connectedTools),
            generations: nonNegativeInteger(candidate.generations),
            other: nonNegativeInteger(candidate.other),
        };
        const computedTotal = Object.values(counts).reduce((sum, count) => sum + count, 0);
        const total = positiveInteger(candidate.total) || computedTotal;
        if (!total)
            return undefined;
        return {
            kind: 'toolSummary',
            total,
            ...Object.fromEntries(Object.entries(counts).filter(([, count]) => count > 0)),
        };
    }
    return undefined;
}
function boundedText(value) {
    const text = typeof value === 'string' ? value.replace(/[\0\r]+/g, ' ').trim() : '';
    return text.length <= TEXT_LIMIT ? text : `${text.slice(0, TEXT_LIMIT - 1).trimEnd()}…`;
}
function positiveInteger(value) {
    const number = Number(value);
    return Number.isSafeInteger(number) && number > 0 ? number : 0;
}
function nonNegativeInteger(value) {
    const number = Number(value);
    return Number.isSafeInteger(number) && number >= 0 ? number : 0;
}
