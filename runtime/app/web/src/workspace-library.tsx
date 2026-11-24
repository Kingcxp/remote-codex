import { useCallback, useEffect, useRef, useState } from 'react';
import type { BridgeRequest } from './bridge-request-manager';
import type { Session } from './app-types';
import { friendlyError } from './app-utils';
import { t } from './i18n';
import './workspace-library.css';

export type WorkspaceLibrary = { projects: { id: string; name: string; path: string }[];
  threads: { id: string; projectId: string | null; pinned: boolean }[] };
const EMPTY: WorkspaceLibrary = { projects: [], threads: [] };
export function useWorkspaceLibrary(request: BridgeRequest, environment: string, threadId: string | null, enabled: boolean, online: boolean) {
  const [snapshot, setSnapshot] = useState<{ key: string; data: WorkspaceLibrary; error: string }>({ key: '', data: EMPTY, error: '' });
  const latest = useRef({ environment, threadId, enabled, online }); latest.current = { environment, threadId, enabled, online };
  const refresh = useCallback(async () => {
    const selection = latest.current;
    if (!selection.enabled || !selection.online || !selection.threadId) return;
    try {
      const data = await request<WorkspaceLibrary>('workspace.library', { threadId: selection.threadId });
      if (latest.current.environment === selection.environment) setSnapshot({ key: selection.environment, data, error: '' });
    } catch (error) {
      if (latest.current.environment === selection.environment) setSnapshot(current => ({ key: selection.environment,
        data: current.key === selection.environment ? current.data : EMPTY, error: friendlyError(error) }));
    }
  }, [request]);
  const fetched = snapshot.key === environment;
  useEffect(() => { if (!fetched && enabled && online && threadId) void refresh(); }, [environment, enabled, online, Boolean(threadId), fetched, refresh]);
  return { data: fetched ? snapshot.data : EMPTY, error: fetched ? snapshot.error : '', refresh };
}

type Message = { id: string; threadId: string; title?: string; role: string; phase: string; text: string; timestamp: string; truncated?: boolean };
export function WorkspaceLibraryDialog({ request, threadId, sessions, library, libraryError, online, onClose, onSelect,
  onRefresh, onNewSession, onArchive, initialTab = 'history' }: {
  request: BridgeRequest; threadId: string | null; sessions: Session[]; library: WorkspaceLibrary; libraryError: string; online: boolean;
  onClose(): void; onSelect(session: Session): void; onRefresh(): Promise<void>; onNewSession(path?: string): void;
  onArchive(session: Session): void; initialTab?: 'history' | 'search' | 'projects';
}) {
  const [tab, setTab] = useState(initialTab);
  const [role, setRole] = useState('user');
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState('');
  const [scope, setScope] = useState('all');
  const [project, setProject] = useState('all');
  const [archive, setArchive] = useState('active');
  const [messages, setMessages] = useState<Message[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [searched, setSearched] = useState(false);
  const [scanned, setScanned] = useState(0);
  const [unavailable, setUnavailable] = useState(0);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [renaming, setRenaming] = useState<Session | null>(null);
  const [name, setName] = useState('');
  const generation = useRef(0), mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    const keydown = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose(); };
    document.addEventListener('keydown', keydown);
    return () => { mounted.current = false; generation.current++; document.removeEventListener('keydown', keydown); };
  }, [onClose]);
  const load = useCallback(async (next: string | null = null) => {
    const version = ++generation.current;
    setBusy(true); setError('');
    if (!next) { setMessages([]); setScanned(0); setUnavailable(0); setCursor(null); }
    try {
      if (tab === 'search' && !query.trim()) throw new Error('history_query_required');
      if (tab === 'history' && !threadId) throw new Error('thread_id_required');
      const page = tab === 'history'
        ? await request<{ messages: Message[]; nextCursor: string | null; scannedBytes: number }>('session.messages.list', { threadId, role, cursor: next })
        : await request<{ matches: Message[]; nextCursor: string | null; scannedBytes: number; unavailable?: number }>('messages.search', {
          query, role, cursor: next, ...(scope === 'current' ? { threadId } : {}),
        });
      if (!mounted.current || version !== generation.current) return;
      const rows = 'messages' in page ? page.messages : page.matches;
      setMessages(current => next ? [...current, ...rows.filter(item => !current.some(previous => previous.id === item.id))] : rows);
      setCursor(page.nextCursor); setSearched(true);
      setScanned(current => current + (page.scannedBytes || 0));
      if ('unavailable' in page) setUnavailable(current => current + (page.unavailable || 0));
    } catch (cause) { if (mounted.current && version === generation.current) setError(friendlyError(cause)); }
    finally { if (mounted.current && version === generation.current) setBusy(false); }
  }, [request, threadId, role, tab, query, scope]);
  useEffect(() => {
    generation.current++; setMessages([]); setCursor(null); setError(''); setSearched(false); setBusy(false);
    if (tab === 'history') void load();
    // Search starts explicitly, so typing does not scan every rollout repeatedly.
  }, [tab, role, threadId]);
  // Continue through pages with no hits automatically; one request at a time.
  useEffect(() => {
    if (!searched || !cursor || busy || error || tab !== 'search' || messages.length >= 40) return;
    const timer = setTimeout(() => void load(cursor), 100);
    return () => clearTimeout(timer);
  }, [searched, cursor, busy, error, tab, messages.length, load]);
  const mutate = async (action: string, payload: Record<string, unknown>) => {
    if (busy) return false;
    setBusy(true); setError('');
    try { await request(action, payload); if (mounted.current) await onRefresh(); return true; }
    catch (cause) { if (mounted.current) setError(friendlyError(cause)); return false; }
    finally { if (mounted.current) setBusy(false); }
  };
  const visible = sessions.filter(session => (project === 'all' || (project === 'none' ? !session.projectId : session.projectId === project))
    && (archive === 'all' || Boolean(session.archived) === (archive === 'archived'))
    && (!filter.trim() || `${session.title} ${session.cwd || ''}`.toLocaleLowerCase().includes(filter.trim().toLocaleLowerCase())))
    .sort((a, b) => Number(Boolean(b.pinned)) - Number(Boolean(a.pinned)));

  return <div className="workspace-overlay" onMouseDown={event => { if (event.target === event.currentTarget) onClose(); }}>
    <section className="workspace-dialog" role="dialog" aria-modal="true" aria-label={t('对话、历史与搜索', 'Conversations, history and search')}>
      <header><strong>{t('对话与项目', 'Conversations and projects')}</strong><button onClick={onClose} aria-label={t('关闭历史与搜索', 'Close history and search')}>×</button></header>
      <nav className="workspace-tabs" aria-label={t('查看内容', 'View')}>
        <button aria-pressed={tab === 'history'} onClick={() => setTab('history')}>{t('消息历史', 'Message history')}</button>
        <button aria-pressed={tab === 'search'} onClick={() => setTab('search')}>{t('全文搜索', 'Full-text search')}</button>
        <button aria-pressed={tab === 'projects'} onClick={() => setTab('projects')}>{t('项目与对话', 'Projects and chats')}</button>
      </nav>
      <form className="workspace-filters" onSubmit={event => { event.preventDefault(); if (tab !== 'projects') void load(); }}>
        {tab !== 'history' && <input aria-label={t('搜索关键词', 'Search keywords')} value={tab === 'projects' ? filter : query} onChange={event => {
          if (tab === 'projects') { setFilter(event.target.value); return; }
          generation.current++; setBusy(false); setSearched(false); setCursor(null); setMessages([]); setQuery(event.target.value);
        }} placeholder={tab === 'projects' ? t('筛选标题或目录', 'Filter titles or folders') : t('搜索消息正文', 'Search message text')} maxLength={300} />}
        {tab !== 'projects' ? <>
          <select aria-label={t('消息类型', 'Message type')} value={role} onChange={event => setRole(event.target.value)}>
            <option value="user">{t('我发送的消息', 'My messages')}</option><option value="all">{t('全部消息', 'All messages')}</option>
            <option value="assistant">{t('Codex 回复', 'Codex replies')}</option><option value="reasoning">{t('思考摘要', 'Reasoning summaries')}</option>
          </select>
          {tab === 'search' && <select aria-label={t('搜索范围', 'Search scope')} value={scope} onChange={event => {
            generation.current++; setScope(event.target.value); setBusy(false); setSearched(false); setCursor(null); setMessages([]);
          }}>
            <option value="all">{t('所有对话（含归档）', 'All chats, including archived')}</option><option value="current">{t('当前对话', 'Current chat')}</option>
          </select>}
          <button disabled={!online || busy || (tab === 'search' && !query.trim())}>{busy ? t('正在读取…', 'Reading…') : tab === 'search' ? t('搜索', 'Search') : t('刷新', 'Refresh')}</button>
        </> : <>
          <select aria-label={t('筛选项目', 'Filter project')} value={project} onChange={event => setProject(event.target.value)}>
            <option value="all">{t('所有项目', 'All projects')}</option><option value="none">{t('未归入项目', 'No project')}</option>
            {library.projects.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
          <select aria-label={t('归档状态', 'Archive status')} value={archive} onChange={event => setArchive(event.target.value)}>
            <option value="active">{t('未归档', 'Active')}</option><option value="archived">{t('已归档', 'Archived')}</option><option value="all">{t('全部', 'All')}</option>
          </select>
          <button type="button" disabled={!online} onClick={() => { onClose(); onNewSession(library.projects.find(p => p.id === project)?.path); }}>{t('新建对话', 'New chat')}</button>
        </>}
      </form>
      {(error || (tab === 'projects' && libraryError)) && <p className="workspace-error" role="alert">{error || libraryError}</p>}
      {tab === 'search' && searched && <p className="workspace-caption">{t(`已找到 ${messages.length} 条 · 已扫描 ${(scanned / 1048576).toFixed(1)} MB`,
        `${messages.length} results · ${(scanned / 1048576).toFixed(1)} MB searched`)}{cursor ? t(' · 仍有历史可继续搜索', ' · More history remains') : t(' · 搜索完成', ' · Search complete')}
        {unavailable > 0 && t(` · ${unavailable} 个历史文件暂不可读`, ` · ${unavailable} history files unavailable`)}</p>}
      {tab === 'history' && <p className="workspace-caption">{t('按时间倒序，包含压缩前保存在主机上的消息。', 'Newest first, including messages saved before compaction.')}</p>}
      <div className="workspace-results">
        {tab === 'projects' ? <>
          <div className="workspace-projects">{library.projects.map(p => <button key={p.id} onClick={() => setProject(p.id)} title={p.path}>{p.name}</button>)}</div>
          {renaming && <form onSubmit={event => { event.preventDefault(); void mutate('session.rename', { threadId: renaming.id, name }).then(success => { if (success && mounted.current) setRenaming(null); }); }}>
            <input autoFocus aria-label={t('新的会话名称', 'New chat title')} value={name} onChange={event => setName(event.target.value)} />
            <button disabled={busy || !name.trim()}>{t('保存名称', 'Save title')}</button><button type="button" onClick={() => setRenaming(null)}>{t('取消', 'Cancel')}</button>
          </form>}
          {visible.map(session => <article className="workspace-session" key={session.id}>
            <button className="workspace-session-title" onClick={() => { onSelect(session); onClose(); }}>{session.pinned ? '★ ' : ''}{session.title}</button>
            <small>{session.projectName || session.cwd || t('未归入项目', 'No project')}{session.archived ? t(' · 已归档', ' · Archived') : ''}</small>
            <div className="workspace-row-actions">
              <button disabled={busy || !online} onClick={() => void mutate('session.pin', { threadId: session.id, pinned: !session.pinned })}>{session.pinned ? t('取消置顶', 'Unpin') : t('置顶', 'Pin')}</button>
              <button disabled={busy || !online} onClick={() => { setRenaming(session); setName(session.title); }}>{t('重命名', 'Rename')}</button>
              {session.archived ? <button disabled={busy || !online} onClick={() => void mutate('session.restore', { threadId: session.id })}>{t('恢复', 'Restore')}</button>
                : <button disabled={busy || !online} onClick={() => { onClose(); onArchive(session); }}>{t('归档', 'Archive')}</button>}
              <select aria-label={t(`移动对话：${session.title}`, `Move chat: ${session.title}`)} disabled={busy || !online} value={session.projectId || ''}
                onChange={event => void mutate('session.move', { threadId: session.id, projectId: event.target.value || null })}>
                <option value="">{t('未归入项目', 'No project')}</option>{library.projects.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </div>
          </article>)}
          {!visible.length && <p>{t('没有符合条件的对话。', 'No matching chats.')}</p>}
        </> : <>
          {messages.map(message => {
            const match = query ? message.text.toLocaleLowerCase().indexOf(query.trim().toLocaleLowerCase()) : -1;
            const start = Math.max(0, match - 120);
            const preview = message.text.slice(start, start + 700);
            return <article className={`workspace-message ${message.role}`} key={message.id}>
              <div className="workspace-message-meta"><strong>{message.role === 'user' ? t('我', 'Me') : message.role === 'reasoning' ? t('思考摘要', 'Reasoning summary')
                : message.phase === 'final_answer' ? t('最终回复', 'Final reply') : t('处理过程', 'Process')}</strong><time>{new Date(message.timestamp).toLocaleString()}</time></div>
              {tab === 'search' && <button className="workspace-session-title" onClick={() => { const session = sessions.find(s => s.id === message.threadId); if (session) { onSelect(session); onClose(); } }}>{message.title || message.threadId}</button>}
              <pre>{expanded.has(message.id) ? message.text : (start ? '…' : '') + preview + (start + preview.length < message.text.length ? '…' : '')}</pre>
              <div className="workspace-row-actions">
                {message.text.length > 700 && <button onClick={() => setExpanded(current => { const next = new Set(current); if (next.has(message.id)) next.delete(message.id); else next.add(message.id); return next; })}>{expanded.has(message.id) ? t('收起', 'Collapse') : t('展开全文', 'Show full text')}</button>}
                <button onClick={() => void navigator.clipboard.writeText(message.text).catch(cause => setError(friendlyError(cause)))}>{t('复制', 'Copy')}</button>
              </div>
            </article>;
          })}
          {!busy && searched && !messages.length && !cursor && <p>{t('没有找到消息。', 'No messages found.')}</p>}
          {cursor && <button className="workspace-more" disabled={busy || !online} onClick={() => void load(cursor)}>{busy ? t('正在读取…', 'Reading…') : tab === 'search' ? t('继续搜索更早的历史', 'Search older history') : t('加载更早的消息', 'Load older messages')}</button>}
        </>}
      </div>
    </section>
  </div>;
}
