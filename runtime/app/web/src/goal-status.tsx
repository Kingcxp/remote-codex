import { useState } from 'react';
import type { NativeDesktopState } from './app-types';
import { t } from './i18n';

export function GoalStatus({ goal, online, stopping, onPause }: {
  goal: NonNullable<NativeDesktopState['goal']>; online: boolean; stopping: boolean; onPause(): void;
}) {
  const [expanded, setExpanded] = useState(false);
  const active = goal.status === 'active';
  const status = active ? t('目标运行中', 'Goal active')
    : goal.status === 'paused' ? t('目标已暂停', 'Goal paused')
      : goal.status === 'complete' || goal.status === 'completed' ? t('目标已完成', 'Goal complete')
        : t('目标已停止', 'Goal stopped');
  return <div className={`goal-status${active ? ' active' : ''}`}>
    <button type="button" className="goal-summary" aria-expanded={expanded}
      aria-label={expanded ? t('收起目标内容', 'Collapse goal') : t('展开目标内容', 'Expand goal')}
      onClick={() => setExpanded(value => !value)}>
      <span className="goal-state">{status}</span>
      <span className="goal-objective">{goal.objective || t('查看目标', 'View goal')}</span>
      <span aria-hidden="true">{expanded ? '▴' : '▾'}</span>
    </button>
    {active && <button className="goal-pause" type="button" disabled={!online || stopping}
      onClick={onPause}>{stopping ? t('正在暂停…', 'Pausing…') : t('暂停目标', 'Pause goal')}</button>}
    {expanded && <p className="goal-detail">{goal.objective || t('主机未提供目标内容', 'The host did not provide an objective.')}</p>}
  </div>;
}
