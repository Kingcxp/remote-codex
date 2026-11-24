/** Desktop's blocking request_user_input is answered through its RPC, never a new prompt. */
export type UserInputQuestion = { id: string; header: string; question: string; isOther: boolean; isSecret: boolean;
  options: Array<{ label: string; description: string }> };
export type UserInputRequest = { id: string; threadId: string; turnId: string | null;
  questions: UserInputQuestion[] };
export type UserInputAnswers = Record<string, { answers: string[] }>;

export function userInputQuestions(value: unknown): UserInputQuestion[] | null {
  if (!Array.isArray(value) || !value.length || value.length > 12) return null;
  const seen = new Set<string>();
  const result: UserInputQuestion[] = [];
  for (const q of value) {
    if (!q || typeof q.id !== 'string' || !q.id || q.id.length > 1024 || seen.has(q.id)
      || typeof q.question !== 'string' || !q.question.trim() || q.question.length > 16000
      || (q.header != null && typeof q.header !== 'string') || (q.options != null && !Array.isArray(q.options))) return null;
    const options = q.options ?? [];
    if (options.length > 20 || options.some((o: any) => !o || typeof o.label !== 'string' || !o.label.trim()
      || o.label.length > 4000 || (o.description != null && typeof o.description !== 'string'))) return null;
    seen.add(q.id);
    result.push({ id: q.id, header: q.header || '', question: q.question, isOther: q.isOther !== false,
      isSecret: q.isSecret === true, options: options.map((o: any) => ({ label: o.label, description: o.description || '' })) });
  }
  return result;
}

export function userInputAnswers(questions: UserInputQuestion[], value: unknown): UserInputAnswers {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('user_input_answers_invalid');
  const entries = Object.entries(value);
  if (entries.length !== questions.length) throw new Error('user_input_answers_invalid');
  return Object.fromEntries(questions.map(q => {
    const answer = entries.find(([key]) => key === q.id)?.[1] as { answers?: unknown } | undefined;
    const values = answer?.answers;
    if (!Array.isArray(values) || values.length !== 1
      || typeof values[0] !== 'string' || !values[0].trim() || values[0].length > 16000
      || (!q.isOther && q.options.length && !q.options.some(o => o.label === values[0]))) {
      throw new Error('user_input_answers_invalid');
    }
    return [q.id, { answers: [values[0].trim()] }];
  }));
}
