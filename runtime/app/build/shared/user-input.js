export function userInputQuestions(value) {
    if (!Array.isArray(value) || !value.length || value.length > 12)
        return null;
    const seen = new Set();
    const result = [];
    for (const q of value) {
        if (!q || typeof q.id !== 'string' || !q.id || q.id.length > 1024 || seen.has(q.id)
            || typeof q.question !== 'string' || !q.question.trim() || q.question.length > 16000
            || (q.header != null && typeof q.header !== 'string') || (q.options != null && !Array.isArray(q.options)))
            return null;
        const options = q.options ?? [];
        if (options.length > 20 || options.some((o) => !o || typeof o.label !== 'string' || !o.label.trim()
            || o.label.length > 4000 || (o.description != null && typeof o.description !== 'string')))
            return null;
        seen.add(q.id);
        result.push({ id: q.id, header: q.header || '', question: q.question, isOther: q.isOther !== false,
            isSecret: q.isSecret === true, options: options.map((o) => ({ label: o.label, description: o.description || '' })) });
    }
    return result;
}
export function userInputAnswers(questions, value) {
    if (!value || typeof value !== 'object' || Array.isArray(value))
        throw new Error('user_input_answers_invalid');
    const entries = Object.entries(value);
    if (entries.length !== questions.length)
        throw new Error('user_input_answers_invalid');
    return Object.fromEntries(questions.map(q => {
        const answer = entries.find(([key]) => key === q.id)?.[1];
        const values = answer?.answers;
        if (!Array.isArray(values) || values.length !== 1
            || typeof values[0] !== 'string' || !values[0].trim() || values[0].length > 16000
            || (!q.isOther && q.options.length && !q.options.some(o => o.label === values[0]))) {
            throw new Error('user_input_answers_invalid');
        }
        return [q.id, { answers: [values[0].trim()] }];
    }));
}
