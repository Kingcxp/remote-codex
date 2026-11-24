import { useRef, useState } from 'react';
import type { BridgeRequest } from './bridge-request-manager';
import type { UserInputRequest } from '../../src/shared/user-input';
import { friendlyError } from './app-utils';
import { t } from './i18n';

export function UserInputCard({ value, request, disabled, onRefresh }: {
  value: UserInputRequest; request: BridgeRequest; disabled: boolean; onRefresh(): Promise<void>;
}) {
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false), [error, setError] = useState('');
  const inFlight = useRef(false);
  const answer = (id: string) => Object.hasOwn(drafts, id) ? drafts[id] : '';
  const ready = value.questions.every(q => answer(q.id).trim());
  async function submit() {
    if (disabled || !ready || inFlight.current) return;
    inFlight.current = true; setBusy(true); setError('');
    try {
      await request('user-input.respond', { threadId: value.threadId, id: value.id,
        answers: Object.fromEntries(value.questions.map(q => [q.id, { answers: [answer(q.id).trim()] }])) });
    } catch (e) { setError(friendlyError(e)); }
    finally {
      await onRefresh().catch(() => {});
      inFlight.current = false; setBusy(false);
    }
  }
  return <form className="async-question-card native-question-card" aria-label={t('电脑端待回答的问题', 'Questions awaiting your answer on Desktop')}
    onSubmit={event => { event.preventDefault(); void submit(); }}>
    <strong>{t('电脑任务正在等你回答', 'Your Desktop task is waiting for your answer')}</strong>
    <p className="native-question-hint">{t('回答会直接交给原任务继续执行。', 'Your answer goes directly to the waiting task.')}</p>
    {value.questions.map(q => <fieldset key={q.id} disabled={disabled || busy}>
      <legend>{q.header ? `${q.header} · ` : ''}{q.question}</legend>
      <div className="async-question-options">{q.options.map((option, index) => <label key={index}>
        <input type="radio" name={`${value.id}:${q.id}`} value={option.label} checked={answer(q.id) === option.label}
          onChange={() => setDrafts(current => ({ ...current, [q.id]: option.label }))} />
        <span>{option.label}{option.description && <small>{option.description}</small>}</span>
      </label>)}</div>
      {(q.isOther || !q.options.length) && (q.isSecret ? <input type="password" autoComplete="off" maxLength={16000}
        aria-label={t(`回答：${q.question}`, `Answer: ${q.question}`)} value={answer(q.id)}
        onChange={event => setDrafts(current => ({ ...current, [q.id]: event.target.value }))} />
        : <textarea rows={2} maxLength={16000} aria-label={t(`回答：${q.question}`, `Answer: ${q.question}`)}
          placeholder={t('输入自己的回答', 'Enter your own answer')} value={answer(q.id)}
          onChange={event => setDrafts(current => ({ ...current, [q.id]: event.target.value }))} />)}
    </fieldset>)}
    {error && <p role="alert">{error}</p>}
    <div className="async-question-actions"><button type="submit" disabled={disabled || busy || !ready}>
      {busy ? t('正在提交…', 'Submitting…') : t('提交回答并继续', 'Submit and continue')}</button></div>
  </form>;
}
