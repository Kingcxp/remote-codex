import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export type QueuedInput = { threadId: string; text: string; requestId: string; imagePath?: string };
type Entry = QueuedInput & { id: string; fingerprint: string; createdAt: number;
  status: 'queued' | 'sending' | 'blocked'; error?: string };
type Receipt = { id: string; fingerprint: string; threadId: string; turnId: string };
type Operation = { id: string; fingerprint: string; status: 'pending' | 'completed'; result?: unknown; error?: string };
type SavedQueue = { version: 1; entries: Entry[]; receipts: Receipt[]; barriers: Record<string, string>; paused?: Record<string, boolean>; operations?: Operation[] };
type Options = {
  path: string; secret: string; pollMs?: number;
  readState(threadId: string, previousTurnId?: string): Promise<{ ready: boolean; previousTurnComplete: boolean }>;
  deliver(input: QueuedInput): Promise<{ turnId: string }>;
  steer?(input: QueuedInput): Promise<{ turnId: string }>;
};

// A browser only enqueues. This connector owns persistence and dispatch, including
// when every browser is disconnected. An uncertain dispatch is never retried.
export class MessageQueue {
  private data: SavedQueue = { version: 1, entries: [], receipts: [], barriers: {} };
  private key: Buffer;
  private timer: NodeJS.Timeout;
  private active = new Map<string, Promise<void>>();
  private operations = new Map<string, Promise<any>>();
  private holds = new Map<string, number>();
  private waitingErrors = new Map<string, string>();
  private stopped = false;

  constructor(private options: Options) {
    this.key = createHash('sha256').update('codex-remote-message-queue-v1\0').update(options.secret).digest();
    if (existsSync(options.path)) {
      try {
        const envelope = JSON.parse(readFileSync(options.path, 'utf8'));
        const decipher = createDecipheriv('aes-256-gcm', this.key, Buffer.from(envelope.nonce, 'base64'));
        decipher.setAuthTag(Buffer.from(envelope.tag, 'base64'));
        this.data = JSON.parse(Buffer.concat([decipher.update(Buffer.from(envelope.ciphertext, 'base64')), decipher.final()]).toString());
        if (this.data.version !== 1 || !Array.isArray(this.data.entries) || !Array.isArray(this.data.receipts)
          || !this.data.barriers || this.data.entries.some(e => !e.id || !e.threadId || typeof e.text !== 'string'
            || !['queued', 'sending', 'blocked'].includes(e.status))) throw new Error();
      } catch { throw new Error('message_queue_storage_unreadable'); }
      // A crash after dispatch but before recording the ACK cannot prove failure.
      for (const entry of this.data.entries) if (entry.status === 'sending') {
        entry.status = 'blocked'; entry.error = 'delivery_unknown';
      }
      this.save();
    }
    this.timer = setInterval(() => this.wake(), options.pollMs ?? 1500);
    this.timer.unref();
  }

  enqueue(input: QueuedInput, deviceId: string) {
    if (this.stopped) throw new Error('message_queue_stopped');
    if (!input.threadId || !input.text.trim() || !input.requestId || !deviceId) throw new Error('message_queue_invalid');
    if (Buffer.byteLength(input.text) > 512 * 1024) throw new Error('message_queue_message_too_large');
    const id = createHash('sha256').update(JSON.stringify([deviceId, input.requestId])).digest('hex');
    const fingerprint = createHash('sha256').update(JSON.stringify([input.threadId, input.text, input.imagePath])).digest('hex');
    const existing = this.data.entries.find(e => e.id === id) || this.data.receipts.find(e => e.id === id);
    if (existing && existing.fingerprint !== fingerprint) throw new Error('message_queue_request_mismatch');
    if (!existing) {
      if (this.data.entries.length >= 200 || this.data.entries.filter(e => e.threadId === input.threadId).length >= 50
        || Buffer.byteLength(JSON.stringify(this.data)) + Buffer.byteLength(input.text) > 8 * 1024 * 1024) {
        throw new Error('message_queue_full');
      }
      const entry: Entry = { ...input, id, fingerprint, createdAt: Date.now(), status: 'queued' };
      this.data.entries.push(entry);
      try { this.save(); } catch (error) { this.data.entries.pop(); throw error; }
    }
    // The acceptance response means durable queue storage, not model delivery.
    return { threadId: input.threadId, delivery: 'queue' as const, queueId: id,
      queued: !this.data.receipts.some(e => e.id === id) };
  }

  list(threadId: string) {
    if (!threadId) throw new Error('thread_id_required');
    return { threadId, paused: Boolean(this.data.paused?.[threadId]), entries: this.data.entries.filter(e => e.threadId === threadId)
      .map(({ id, text, imagePath, createdAt, status, error }) => ({ id, text, hasImage: Boolean(imagePath), createdAt, status,
        error: error || this.waitingErrors.get(id) })) };
  }

  async setPaused(threadId: string, paused: boolean) {
    if (!threadId) throw new Error('thread_id_required');
    const previous = this.data.paused;
    this.data.paused = { ...previous, [threadId]: paused };
    try { this.save(); } catch (error) { this.data.paused = previous; throw error; }
    // A Stop must wait for an already dispatched send, then interrupt that work.
    // A state read that is still pending will observe paused before dispatch.
    if (paused) await this.active.get(threadId)?.catch(() => {});
    return this.list(threadId);
  }

  // A short control operation must also block messages added to an empty queue.
  // This hold is separate from the user's persistent pause of pending messages.
  async hold(threadId: string) {
    if (!threadId) throw new Error('thread_id_required');
    this.holds.set(threadId, (this.holds.get(threadId) || 0) + 1);
    await this.active.get(threadId)?.catch(() => {});
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const count = (this.holds.get(threadId) || 1) - 1;
      if (count) this.holds.set(threadId, count); else this.holds.delete(threadId);
    };
  }

  async runOperation(device: string, requestId: string, payload: unknown, run: () => Promise<unknown>): Promise<any> {
    if (this.stopped) throw new Error('message_queue_stopped');
    if (!device || !requestId) throw new Error('message_queue_invalid');
    const id = createHash('sha256').update(JSON.stringify([device, requestId])).digest('hex');
    const fingerprint = createHash('sha256').update(JSON.stringify(payload)).digest('hex');
    const existing = this.data.operations?.find(item => item.id === id);
    if (existing) {
      if (existing.fingerprint !== fingerprint) throw new Error('message_queue_request_mismatch');
      const pending = this.operations.get(id);
      if (pending) return pending;
      if (existing.status === 'pending') throw new Error('desktop_operation_unknown');
      if (existing.error) throw new Error(existing.error);
      return existing.result;
    }
    const operation: Operation = { id, fingerprint, status: 'pending' };
    this.data.operations = [...(this.data.operations || []).filter(item => item.status === 'pending').slice(-100),
      ...(this.data.operations || []).filter(item => item.status === 'completed').slice(-500), operation];
    // Checkpoint before invoking Desktop. A crash keeps the mutation uncertain,
    // so reconnect cannot execute a second compaction or another Stop later.
    this.save();
    const running = (async () => {
      try { const result = await run(); operation.result = result; operation.status = 'completed'; this.save(); return result; }
      catch (error) {
        operation.status = 'completed'; operation.error = String((error as Error).message || error).slice(0, 500);
        this.save(); throw error;
      }
    })().finally(() => this.operations.delete(id));
    this.operations.set(id, running);
    return running;
  }

  async steer(threadId: string, id: string) {
    if (this.stopped) throw new Error('message_queue_stopped');
    if (!this.options.steer) throw new Error('message_queue_steer_unavailable');
    // Serialize with both the automatic dispatcher and another Guide click.
    const previous = this.active.get(threadId);
    if (previous) await previous.catch(() => {});
    if (this.active.has(threadId) || this.holds.has(threadId)) throw new Error('message_queue_sending');
    const entry = this.data.entries.find(e => e.threadId === threadId && e.id === id);
    if (!entry) {
      const receipt = this.data.receipts.find(e => e.threadId === threadId && e.id === id);
      if (receipt?.turnId) return { threadId, turnId: receipt.turnId, delivered: true };
      throw new Error('message_queue_entry_missing');
    }
    if (entry.status !== 'queued') throw new Error('message_queue_sending');
    const sending = this.dispatchEntry(entry, this.options.steer);
    const lock = sending.then(() => {}).finally(() => { if (this.active.get(threadId) === lock) this.active.delete(threadId); });
    this.active.set(threadId, lock);
    // The caller receives a failure; the scheduling lock must not reject unhandled.
    void lock.catch(() => {});
    const result = await sending;
    return { threadId, turnId: result.turnId, delivered: true };
  }

  remove(threadId: string, id: string) {
    const entry = this.data.entries.find(e => e.threadId === threadId && e.id === id);
    if (!entry) return { threadId, removed: false };
    if (entry.status === 'sending') throw new Error('message_queue_sending');
    const before = this.data.entries;
    this.data.entries = before.filter(e => e !== entry);
    // Keep a tombstone so reconnect/replay cannot re-add a cancelled message.
    this.data.receipts.push({ id, fingerprint: entry.fingerprint, threadId, turnId: '' });
    try { this.save(); } catch (error) { this.data.entries = before; this.data.receipts.pop(); throw error; }
    return { threadId, removed: true };
  }

  wake() {
    if (this.stopped) return;
    for (const threadId of new Set(this.data.entries.map(e => e.threadId))) {
      if (this.active.has(threadId) || this.holds.has(threadId) || this.data.paused?.[threadId]) continue;
      const running = this.drain(threadId).finally(() => this.active.delete(threadId));
      this.active.set(threadId, running);
      // A storage failure must not crash the connector or start another message.
      void running.catch(() => {});
    }
  }

  private async drain(threadId: string) {
    const head = this.data.entries.find(e => e.threadId === threadId);
    if (!head || head.status !== 'queued') return;
    let state;
    try { state = await this.options.readState(threadId, this.data.barriers[threadId]); }
    catch (error) { this.waitingErrors.set(head.id, String((error as Error).message)); return; }
    this.waitingErrors.delete(head.id);
    // A recovered connection must not keep showing a stale send failure while
    // the task is simply busy. Blocked/uncertain submissions are never cleared.
    if (head.status === 'queued' && head.error && this.data.entries.includes(head)) {
      delete head.error; this.save();
    }
    if (this.stopped || this.holds.has(threadId) || this.data.paused?.[threadId] || !state.ready || !state.previousTurnComplete || !this.data.entries.includes(head)
      || head.status !== 'queued') return;
    await this.dispatchEntry(head, this.options.deliver).catch(() => {});
  }

  private async dispatchEntry(head: Entry, deliver: Options['deliver']) {
    const threadId = head.threadId;
    head.status = 'sending';
    try { this.save(); } catch (error) { head.status = 'blocked'; head.error = 'storage_failed'; throw error; }
    try {
      const result = await deliver({ threadId, text: head.text, requestId: head.id,
        ...(head.imagePath ? { imagePath: head.imagePath } : {}) });
      if (!result.turnId) throw new Error('desktop_delivery_unknown');
      this.data.entries = this.data.entries.filter(e => e !== head);
      // A later enqueue can beat Desktop's transition from idle to active.
      this.data.barriers[threadId] = result.turnId;
      this.waitingErrors.delete(head.id);
      this.data.receipts.push({ id: head.id, fingerprint: head.fingerprint, threadId, turnId: result.turnId });
      this.data.receipts = this.data.receipts.slice(-2000);
      this.save();
      return result;
    } catch (error) {
      // These errors prove that no user input was handed to the host. Retry
      // them after reconnection; uncertain dispatches must stay blocked.
      const message = (error as Error).message;
      if (!this.data.entries.includes(head)) this.data.entries.unshift(head);
      const retry = ['desktop_queue_busy', 'desktop_input_unavailable', 'desktop_input_not_ready', 'desktop_input_settings_failed'].includes(message);
      head.status = retry ? 'queued' : 'blocked';
      head.error = message === 'desktop_delivery_unknown' ? 'delivery_unknown' : message || 'delivery_failed';
      this.save();
      throw error;
    }
  }

  private save() {
    this.data.receipts = this.data.receipts.slice(-2000);
    // A pause applies to the pending messages. Once the queue is empty, a later
    // explicit submission starts normally. Also repairs old empty paused queues.
    const threads = new Set(this.data.entries.map(entry => entry.threadId));
    const paused = Object.fromEntries(Object.entries(this.data.paused || {}).filter(([id, value]) => value && threads.has(id)));
    const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', this.key, nonce);
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify({ ...this.data, paused })), cipher.final()]);
    const temporary = this.options.path + '.' + randomUUID() + '.tmp';
    mkdirSync(dirname(this.options.path), { recursive: true, mode: 0o700 });
    writeFileSync(temporary, JSON.stringify({ version: 1, nonce: nonce.toString('base64'),
      tag: cipher.getAuthTag().toString('base64'), ciphertext: ciphertext.toString('base64') }), { mode: 0o600, flag: 'wx' });
    renameSync(temporary, this.options.path);
    this.data.paused = paused;
  }

  async close() {
    this.stopped = true; clearInterval(this.timer);
    await Promise.allSettled([...this.active.values(), ...this.operations.values()]);
  }
}
