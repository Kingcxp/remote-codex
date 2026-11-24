import { useCallback, useEffect, useRef, useState } from 'react';
import type { BridgeRequest } from './bridge-request-manager';
import { friendlyError } from './app-utils';
import { t } from './i18n';
import type { DesktopQueueEntry } from '../../src/connector/desktop-pending-queue';

type DesktopQueue = { entries: DesktopQueueEntry[]; available: boolean };
type QueueSnapshot = { key: string; entries: QueueEntry[]; error: string; paused?: boolean; desktopQueue?: DesktopQueue };

export type QueueEntry = { id: string; text: string; hasImage: boolean; createdAt: number;
  status: 'queued' | 'sending' | 'blocked'; error?: string };

export function useMessageQueue(request: BridgeRequest, environment: string, threadId: string | null, enabled: boolean, online: boolean) {
  const [snapshot, setSnapshot] = useState<QueueSnapshot>({ key: '', entries: [], error: '' });
  const refreshRef = useRef<(afterMutation?: boolean) => Promise<void>>(async () => {});
  const key = JSON.stringify([environment, threadId]);
  const selectedKey = useRef(key);
  selectedKey.current = key;
  useEffect(() => {
    let cancelled = false, pending: Promise<void> | null = null;
    const refresh = async (afterMutation = false): Promise<void> => {
      if (cancelled || !enabled || !online || !threadId) return;
      if (pending) {
        await pending;
        if (afterMutation) await refresh();
        return;
      }
      pending = (async () => {
        try {
          const result = await request<{ threadId: string; entries: QueueEntry[]; paused?: boolean; desktopQueue?: DesktopQueue }>('queue.list', { threadId });
          if (!cancelled && result.threadId === threadId) setSnapshot({ key, entries: result.entries, error: '', paused: result.paused,
            desktopQueue: result.desktopQueue });
        } catch (error) {
          if (!cancelled) setSnapshot(current => ({ ...(current.key === key ? current : { key, entries: [] }), error: friendlyError(error) }));
        }
      })().finally(() => { pending = null; });
      await pending;
    };
    refreshRef.current = refresh;
    void refresh();
    const timer = setInterval(() => void refresh(), 2000);
    return () => { cancelled = true; clearInterval(timer); };
  }, [request, environment, threadId, enabled, online, key]);
  const refreshQueue = useCallback(() => refreshRef.current(), []);
  const change = useCallback(async (action: string, payload: Record<string, unknown>) => {
    try {
      await request(action, { threadId, ...payload });
      if (selectedKey.current === key) await refreshRef.current(true);
    } catch (error) {
      if (selectedKey.current === key) setSnapshot(current => ({ ...(current.key === key ? current : { key, entries: [] }), error: friendlyError(error) }));
    }
  }, [request, threadId, key]);
  return { entries: snapshot.key === key ? snapshot.entries : [], error: snapshot.key === key ? snapshot.error : '',
    desktopQueue: snapshot.key === key ? snapshot.desktopQueue : undefined,
    paused: snapshot.key === key && snapshot.entries.length > 0 && Boolean(snapshot.paused), refreshQueue,
    remove: (id: string) => change('queue.remove', { id }), steer: (id: string) => change('queue.steer', { id }),
    setPaused: (paused: boolean) => change('queue.pause', { paused }) };
}

export function DesktopQueuePanel({ queue }: { queue?: DesktopQueue }) {
  if (!queue || queue.available && !queue.entries.length) return null;
  return <details className="message-queue desktop-message-queue" open aria-label={t('电脑待发送消息', 'Desktop queued messages')}>
    <summary>{!queue.entries.length && !queue.available ? t('电脑队列状态暂不可用', 'Desktop queue status unavailable')
      : t(`电脑待发送 ${queue.entries.length} 条`, `${queue.entries.length} queued on Desktop`)}</summary>
    <p className="native-question-hint">{t('由电脑端队列发送；在电脑上的修改会同步到这里。', 'Sent by the Desktop queue; changes on your computer appear here.')}</p>
    {!queue.available && <p className="message-queue-error" role="status">{t('部分电脑队列暂时无法读取，正在重试；列表可能不完整。', 'Part of the Desktop queue is unavailable; retrying. This list may be incomplete.')}</p>}
    <ol>{queue.entries.map((entry, index) => <li key={entry.id}><div className="message-queue-content">
      <span className="message-queue-text">{index + 1}. {entry.hasImage ? '▧ ' : ''}{entry.hasFiles ? '📎 ' : ''}{entry.text || t('附件消息', 'Attachment message')}</span>
      <small>{entry.status === 'paused' ? t('已暂停', 'Paused') : entry.status === 'unknown' ? t('发送结果待确认', 'Delivery awaiting confirmation')
        : entry.status === 'sending' ? t('正在发送…', 'Sending…') : t('电脑排队中', 'Queued on Desktop')}{entry.reason ? ` · ${entry.reason}` : ''}</small>
    </div></li>)}</ol>
  </details>;
}

export function MessageQueuePanel({ entries, error, online, paused = false, onRemove, onSteer, onPause }: {
  entries: QueueEntry[]; error: string; online: boolean; paused?: boolean; onRemove(id: string): Promise<void>;
  onSteer?(id: string): Promise<void>; onPause?(paused: boolean): Promise<void>;
}) {
  const [busy, setBusy] = useState('');
  const run = async (id: string, action: () => Promise<void>) => { if (busy) return; setBusy(id); try { await action(); } finally { setBusy(''); } };
  if (!entries.length && !error) return null;
  return <section className="message-queue" aria-label={t('待发送消息', 'Queued messages')}>
    <div className="message-queue-heading">{!entries.length ? t('暂时无法读取待发队列', 'Queue status unavailable')
      : paused ? t(`远程队列已暂停 · 保留 ${entries.length} 条`, `Remote queue paused · ${entries.length} saved`)
      : t(`远程待发送 ${entries.length} 条 · 依次发送`, `${entries.length} queued remotely · sent in order`)}
      {onPause && entries.length > 0 && <button type="button" disabled={!online || Boolean(busy)} onClick={() => void run('pause', () => onPause(!paused))}>
        {paused ? t('继续队列', 'Resume queue') : t('暂停队列', 'Pause queue')}</button>}</div>
    {error && <div className="message-queue-error" role="status">{error}</div>}
    <ol>{entries.map(entry => <li key={entry.id}>
      <div className="message-queue-content">
        <span className="message-queue-text">{entry.hasImage ? '▧ ' : ''}{entry.text}</span>
        {entry.status !== 'queued' && <small>{entry.status === 'sending'
          ? t('正在发送…', 'Sending…') : entry.error === 'delivery_unknown'
            ? t('发送结果待确认，后续消息已暂停。请检查对话，再取消此条以免重复。', 'Delivery is uncertain; later messages are paused. Check the conversation, then remove this entry to avoid duplicates.')
            : t('发送失败，后续消息已暂停。请复制内容、取消此条，再重新发送。', 'Delivery failed; later messages are paused. Copy the text, remove this entry, then send again.')}</small>}
      </div>
      <div className="message-queue-actions">
      {onSteer && <button type="button" disabled={!online || Boolean(busy) || entry.status !== 'queued'}
        onClick={() => void run(entry.id, () => onSteer(entry.id))} title={t('立即发送给正在运行的任务；空闲时开始新一轮', 'Send to the active task now, or start a turn when idle')}>{t('立即引导', 'Guide now')}</button>}
      <button type="button" disabled={!online || Boolean(busy) || entry.status === 'sending'} onClick={() => void run(entry.id, () => onRemove(entry.id))}
        aria-label={t(`取消排队消息：${entry.text.slice(0, 40)}`, `Remove queued message: ${entry.text.slice(0, 40)}`)}>{t('取消', 'Remove')}</button>
      </div>
    </li>)}</ol>
  </section>;
}
