// Keep keyboard behavior independent of render timing and IME composition.
export function composerAction(event: { key: string; shiftKey: boolean; ctrlKey: boolean; metaKey: boolean;
  altKey: boolean; isComposing?: boolean; keyCode?: number }): 'queue' | 'steer' | null {
  if (event.isComposing || event.keyCode === 229 || event.key !== 'Enter' || event.shiftKey || event.altKey) return null;
  return event.ctrlKey || event.metaKey ? 'steer' : 'queue';
}

export class ComposerHistory {
  private entries: string[] = [];
  private index: number | null = null;
  private recalled = '';
  constructor(entries: string[] = []) { this.seed(entries); }
  seed(entries: string[]) { this.entries = entries.filter(text => text.trim()).slice(-200); this.reset(); }
  record(text: string) {
    if (text.trim() && this.entries.at(-1) !== text) this.entries = [...this.entries, text].slice(-200);
    this.reset();
  }
  values() { return [...this.entries]; }
  reset() { this.index = null; this.recalled = ''; }
  navigate(direction: 'ArrowUp' | 'ArrowDown', draft: string): string | null {
    // Up/Down remain ordinary cursor movement for a new or edited draft.
    if (this.index === null && draft !== '' || this.index !== null && draft !== this.recalled) { this.reset(); return null; }
    if (!this.entries.length || this.index === null && direction === 'ArrowDown') return null;
    const next = (this.index ?? this.entries.length) + (direction === 'ArrowUp' ? -1 : 1);
    this.index = Math.max(0, Math.min(this.entries.length, next));
    this.recalled = this.entries[this.index] || '';
    if (this.index === this.entries.length) this.reset();
    return this.recalled;
  }
}
