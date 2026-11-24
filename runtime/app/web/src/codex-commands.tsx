import { useEffect, useRef, useState } from 'react';
import type { BridgeRequest } from './bridge-request-manager';
import type { NativeDesktopState } from './app-types';
import { friendlyError } from './app-utils';
import { t } from './i18n';

export function CodexCommands({ request, threadId, online, onClose, onChanged, onStop, onGoalRequest }: {
  request: BridgeRequest; threadId: string; online: boolean; onClose(): void; onChanged(): void;
  onStop(): Promise<void>; onGoalRequest(objective: string): Promise<void>;
}) {
  const [state, setState] = useState<NativeDesktopState | null>(null);
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [notice, setNotice] = useState('');
  const [objective, setObjective] = useState('');
  const [syncError, setSyncError] = useState('');
  const mounted = useRef(true);
  const revision = useRef(0);
  useEffect(() => {
    let cancelled = false, reading = false;
    mounted.current = true;
    const read = async () => {
      if (!online || reading) return; reading = true;
      const version = revision.current;
      try { const next = await request<NativeDesktopState>('session.desktop.state', { threadId }); if (!cancelled && version === revision.current) { setState(next); setSyncError(''); } }
      catch (cause) { if (!cancelled && version === revision.current) { setState(null); setSyncError(friendlyError(cause)); } }
      finally { reading = false; }
    };
    void read(); const timer = setInterval(() => void read(), 2500);
    return () => { cancelled = true; mounted.current = false; clearInterval(timer); };
  }, [request, threadId, online]);
  const run = async (action: () => Promise<unknown>, success: string) => {
    if (busy) return;
    const version = ++revision.current;
    setBusy(true); setError(''); setNotice('');
    try {
      await action();
      if (mounted.current && version === revision.current) {
        setNotice(success); onChanged();
        const next = await request<NativeDesktopState>('session.desktop.state', { threadId }).catch(() => null);
        if (next && mounted.current && version === revision.current) setState(next);
      }
    }
    catch (cause) { if (mounted.current) setError(friendlyError(cause)); }
    finally { if (mounted.current) setBusy(false); }
  };
  const active = Boolean(state?.canStop);
  const synced = Boolean(state && state.status !== 'unknown');
  return <div className="workspace-overlay" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="workspace-dialog" style={{ maxWidth: 620, height: 'auto', maxHeight: '92dvh' }} role="dialog" aria-modal="true" aria-label={t('Codex 控制', 'Codex controls')}>
      <header><strong>{t('Codex 控制', 'Codex controls')}</strong><button onClick={onClose} aria-label={t('关闭控制面板', 'Close controls')}>×</button></header>
      <div className="codex-command">
        <p>{t('手动压缩当前对话的上下文，或切换下一轮的计划模式。', 'Compact this chat’s context, or switch planning for the next turn.')}</p>
        <p className="desktop-mode-status">{!synced ? t('电脑模式尚未同步', 'Desktop mode has not synced')
          : state?.collaborationMode === 'plan' ? t('当前电脑模式：计划', 'Current Desktop mode: Plan') : t('当前电脑模式：普通', 'Current Desktop mode: Default')}</p>
        {syncError && <p className="workspace-error" role="status">{syncError}</p>}
        <div className="workspace-row-actions">
          <button disabled={!online || busy || active} onClick={() => void run(() => request('session.compact', { threadId }), t('主机已接受压缩请求。', 'The host accepted the compaction request.'))}>{t('主动压缩 /compact', 'Compact /compact')}</button>
          <button disabled={!online || busy || active || !synced} onClick={() => void run(() => request('session.plan', { threadId, mode: state?.collaborationMode === 'plan' ? 'default' : 'plan' }),
            state?.collaborationMode === 'plan' ? t('已切换到普通模式。', 'Switched to default mode.') : t('已切换到计划模式。', 'Switched to plan mode.'))}>
            {state?.collaborationMode === 'plan' ? t('退出计划 /plan off', 'Exit plan /plan off') : t('计划模式 /plan', 'Plan mode /plan')}</button>
        </div>
        <p>{t('持续目标', 'Persistent goal')}：{state?.goal ? `${state.goal.status} · ${state.goal.objective || ''}` : t('主机尚未报告目标', 'No goal reported by the host')}</p>
        {state?.goal?.tokensUsed != null && <p>{t('目标累计用量', 'Goal token usage')}：{state.goal.tokensUsed.toLocaleString()}</p>}
        <div className="workspace-row-actions">
          <button disabled={!online || busy || !active} onClick={() => void run(onStop, t('任务已停止；已有待发消息保留并暂停。', 'Work stopped; pending messages, if any, are saved and paused.'))}>{t('停止任务 / 暂停目标', 'Stop work / pause goal')}</button>
        </div>
        <label>{t('请求 Codex 创建目标', 'Ask Codex to create a goal')}
          <textarea value={objective} onChange={event => setObjective(event.target.value)} placeholder={t('描述你希望持续推进的目标', 'Describe the goal you want Codex to pursue')} /></label>
        <p>{t('这会发送一条明确的目标创建请求，由 Codex 的目标工具执行。目标状态以主机确认为准；创建、恢复和清除目标尚无可用的远程原生接口。',
          'This sends an explicit goal request for Codex’s goal tool to execute. Host state confirms the result. Native remote create, resume and clear APIs are not available.')}</p>
        <button disabled={!online || busy || !objective.trim()} onClick={() => void run(() => onGoalRequest(objective.trim()), t('目标请求已加入队列；可在队列中点击立即引导。', 'Goal request queued; use Guide now to send it immediately.'))}>{t('发送目标请求', 'Send goal request')}</button>
        {error && <p className="workspace-error" role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
      </div>
    </section>
  </div>;
}
