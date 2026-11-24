import { Fragment, memo, useMemo, useState } from 'react';
import {
  formatDate,
  isSessionRunning,
  sessionProjectName,
  sessionUpdatedAt,
  type SessionAttentionState,
} from './app-utils';
import type { ExecutionState, Session } from './app-types';
import { t } from './i18n';
import { SidebarIcon } from './ui-components';
import { EnvironmentSwitcher } from './environment-switcher';
import type { EnvironmentLabels } from './execution-environments';

type SessionSidebarProps = {
  open: boolean;
  environmentId: string;
  environmentIds: string[];
  environmentLabels?: EnvironmentLabels;
  onEnvironmentRename?: (id: string, label: string) => Promise<void>;
  onlineEnvironmentIds: string[];
  sessions: Session[];
  selectedThreadId: string | null;
  executionState: ExecutionState;
  attention: SessionAttentionState;
  searchOpen: boolean;
  search: string;
  onSearchOpenChange: (open: boolean) => void;
  onSearchChange: (search: string) => void;
  onEnvironmentChange: (environmentId: string) => void;
  onNewSession: () => void;
  onLibrary?: () => void;
  onClose: () => void;
  onSelect: (session: Session) => void;
};

/**
 * Kept outside App so prompt typing and live progress updates do not rebuild a
 * potentially long session list. It still refreshes for real session/status changes.
 */
export const SessionSidebar = memo(function SessionSidebar({
  open,
  environmentId,
  environmentIds,
  environmentLabels,
  onEnvironmentRename,
  onlineEnvironmentIds,
  sessions,
  selectedThreadId,
  executionState,
  attention,
  searchOpen,
  search,
  onSearchOpenChange,
  onSearchChange,
  onEnvironmentChange,
  onNewSession,
  onLibrary,
  onClose,
  onSelect,
}: SessionSidebarProps) {
  const [projectFilter, setProjectFilter] = useState('all');
  const groupName = (session: Session) => session.pinned ? t('置顶', 'Pinned')
    : (session.archived ? t('已归档 · ', 'Archived · ') : '') + (session.projectName || sessionProjectName(session.cwd) || t('未归入项目', 'No project'));
  const visibleSessions = useMemo(() => {
    const query = search.trim().toLocaleLowerCase();
    const matches = query
      ? sessions.filter((session) => `${session.title} ${session.cwd || ''} ${session.preview || ''}`
        .toLocaleLowerCase().includes(query))
      : sessions;
    return [...matches].filter(session => projectFilter === 'all' || (session.projectId || session.cwd || '') === projectFilter)
      .sort((left, right) => Number(Boolean(right.pinned)) - Number(Boolean(left.pinned))
        || Number(Boolean(left.archived)) - Number(Boolean(right.archived))
        || (left.projectName || sessionProjectName(left.cwd) || '').localeCompare(right.projectName || sessionProjectName(right.cwd) || '')
        || sessionUpdatedAt(right.updatedAt) - sessionUpdatedAt(left.updatedAt));
  }, [search, sessions, projectFilter]);
  const projects = [...new Map(sessions.map(session => [session.projectId || session.cwd || '', session.projectName || sessionProjectName(session.cwd) || t('未归入项目', 'No project')])).entries()];

  return (
    <aside className={`sidebar ${open ? 'open' : ''}`} aria-label={t('会话列表', 'Session list')}>
      <div className="sidebar-head">
        <div><p className="eyebrow">CODEX ANYWHERE</p></div>
        <div className="sidebar-actions">
          <button className="sidebar-tool" onClick={onNewSession} aria-label={t('新会话', 'New session')} title={t('新会话', 'New session')}>
            <SidebarIcon name="plus" />
          </button>
          <button
            className={`sidebar-tool ${searchOpen ? 'active' : ''}`}
            onClick={() => {
              if (searchOpen) onSearchChange('');
              onSearchOpenChange(!searchOpen);
            }}
            aria-label={searchOpen ? t('收起搜索', 'Collapse search') : t('搜索会话', 'Search sessions')}
            title={searchOpen ? t('收起搜索', 'Collapse search') : t('搜索会话', 'Search sessions')}
          >
            <SidebarIcon name="search" />
          </button>
          <button className="sidebar-tool mobile-only" onClick={onClose} aria-label={t('收起会话列表', 'Collapse session list')} title={t('收起会话列表', 'Collapse session list')}>
            <SidebarIcon name="panel-close" />
          </button>
        </div>
      </div>
      <EnvironmentSwitcher value={environmentId} environmentIds={environmentIds}
        labels={environmentLabels} onRename={onEnvironmentRename}
        onlineEnvironmentIds={onlineEnvironmentIds} onChange={onEnvironmentChange} />
      <div className="workspace-filters">
        <select aria-label={t('侧栏项目', 'Sidebar project')} value={projectFilter} onChange={event => setProjectFilter(event.target.value)} style={{ maxWidth: '100%', minWidth: 0 }}>
          <option value="all">{t('所有项目', 'All projects')}</option>{projects.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
        </select>
        {onLibrary && <button className="workspace-open" onClick={onLibrary}>{t('管理 / 全文搜索', 'Manage / Search')}</button>}
      </div>
      {searchOpen && (
        <label className="compact-search session-search-panel">
          <span className="compact-search-icon"><SidebarIcon name="search" /></span>
          <input
            autoFocus
            value={search}
            onChange={(event) => onSearchChange(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Escape') {
                onSearchChange('');
                onSearchOpenChange(false);
              }
            }}
            placeholder={t('搜索会话或目录', 'Search sessions or folders')}
          />
        </label>
      )}
      <nav className="session-list">
        {visibleSessions.map((session, index) => {
          const sessionRunning = isSessionRunning(session.status)
            || attention[session.id] === 'running'
            || (session.id === selectedThreadId
              && (executionState === 'running' || executionState === 'waiting'));
          const completedUnread = !sessionRunning && attention[session.id] === 'unread';
          const projectName = session.projectName || sessionProjectName(session.cwd);
          return (
            <Fragment key={session.id}>
            {(index === 0 || groupName(visibleSessions[index - 1]) !== groupName(session)) && <span className="sidebar-group-title">{groupName(session)}</span>}
            <button
              key={session.id}
              className={`session-card ${selectedThreadId === session.id ? 'active' : ''} ${sessionRunning ? 'running' : ''} ${completedUnread ? 'completed-unread' : ''}`}
              onClick={() => onSelect(session)}
            >
              <span className="session-title" title={session.title || session.id}>{session.pinned ? '★ ' : ''}{session.title || session.id}</span>
              <span className="session-meta">
                {session.archived && <span>{t('已归档 · 恢复后打开', 'Archived · restore to open')}</span>}
                {sessionRunning && <span className="session-running-dot" aria-label={t('运行中', 'Running')} title={t('运行中', 'Running')} />}
                {completedUnread && <span className="session-unread-dot" aria-label={t('已完成，未读', 'Completed, unread')} title={t('已完成，未读', 'Completed, unread')} />}
                <span
                  className={projectName ? 'session-project' : 'session-project placeholder'}
                  title={projectName ? session.cwd : undefined}
                >
                  {projectName || 'General session'}
                </span>
                <time>{formatDate(session.updatedAt)}</time>
              </span>
            </button>
            </Fragment>
          );
        })}
        {!visibleSessions.length && <p className="empty-list">{t('没有匹配的会话', 'No matching sessions')}</p>}
      </nav>
    </aside>
  );
});
