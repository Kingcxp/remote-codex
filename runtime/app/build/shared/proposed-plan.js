/** The rollout format wraps proposed plans in a control tag. Do not strip quoted examples. */
export function proposedPlanText(value) {
    if (typeof value !== 'string')
        return null;
    const text = value.trim();
    const match = /^<proposed_plan>\s*([\s\S]*?)\s*<\/proposed_plan>$/.exec(text);
    return match ? match[1].trim() : null;
}
