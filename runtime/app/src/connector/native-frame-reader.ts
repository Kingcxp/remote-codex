// Copy fragmented frames once instead of repeatedly concatenating the entire
// partial payload. Bounded channels reject the length before allocation;
// trusted Desktop snapshots use null and buffer only bytes actually received.
export class NativeFrameReader {
  private header = Buffer.alloc(4);
  private headerBytes = 0;
  private body: Buffer | null = null;
  private bodyLength = 0;
  private chunks: Buffer[] = [];
  private bodyBytes = 0;
  constructor(private maxBytes: number | null) {}
  clear() { this.headerBytes = 0; this.body = null; this.bodyLength = 0; this.chunks = []; this.bodyBytes = 0; }
  push(chunk: Buffer, consume: (body: Buffer) => boolean) {
    let offset = 0;
    while (offset < chunk.length) {
      if (!this.bodyLength) {
        const count = Math.min(4 - this.headerBytes, chunk.length - offset);
        chunk.copy(this.header, this.headerBytes, offset, offset + count);
        this.headerBytes += count; offset += count;
        if (this.headerBytes < 4) return;
        const length = this.header.readUInt32LE(0);
        if (!length || (this.maxBytes !== null && length > this.maxBytes)) { this.clear(); throw new Error('invalid frame size'); }
        this.bodyLength = length;
        this.body = this.maxBytes === null ? null : Buffer.allocUnsafe(length);
      }
      const count = Math.min(this.bodyLength - this.bodyBytes, chunk.length - offset);
      if (this.body) chunk.copy(this.body, this.bodyBytes, offset, offset + count);
      else this.chunks.push(Buffer.from(chunk.subarray(offset, offset + count)));
      this.bodyBytes += count; offset += count;
      if (this.bodyBytes === this.bodyLength) {
        const body = this.body ?? (this.chunks.length === 1 ? this.chunks[0] : Buffer.concat(this.chunks, this.bodyLength));
        this.clear();
        if (!consume(body)) return;
      }
    }
  }
}
