// Minimal RFC 6455 client that never offers permessage-deflate. Browsers
// (and Node's built-in WebSocket) always offer it, so this is the only way
// to get an UNCOMPRESSED reference connection to compare the compressed
// game socket against. Text frames only — that's all Phoenix's JSON
// serializer sends.
const http = require('http');
const crypto = require('crypto');

class RawSocket {
  constructor(socket, head, headers) {
    this.socket = socket;
    this.headers = headers;
    this.buf = head || Buffer.alloc(0);
    this.frags = [];
    this.messages = [];
    this.waiters = [];
    this.closed = null;
    this.reservedBitsSeen = false;
    socket.on('data', (d) => { this.buf = Buffer.concat([this.buf, d]); this.parse(); });
    socket.on('close', () => { this.closed = this.closed || { code: 1006 }; this.wake(); });
  }

  parse() {
    for (;;) {
      if (this.buf.length < 2) return;
      const b0 = this.buf[0];
      let len = this.buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (this.buf.length < 4) return;
        len = this.buf.readUInt16BE(2); off = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return;
        len = Number(this.buf.readBigUInt64BE(2)); off = 10;
      }
      if (this.buf.length < off + len) return;
      const payload = this.buf.subarray(off, off + len);
      this.buf = this.buf.subarray(off + len);
      // RSV1 would mean the server compressed a frame we never negotiated.
      if (b0 & 0x70) this.reservedBitsSeen = true;
      const op = b0 & 0x0f;
      if (op === 0x8) {
        this.closed = { code: payload.length >= 2 ? payload.readUInt16BE(0) : 1005 };
        this.socket.end();
      } else if (op === 0x9) {
        this.sendFrame(0xa, payload);
      } else if (op === 0x1 || op === 0x0) {
        this.frags.push(payload);
        if (b0 & 0x80) {
          this.messages.push(Buffer.concat(this.frags).toString('utf8'));
          this.frags = [];
        }
      }
      this.wake();
    }
  }

  wake() {
    const waiters = this.waiters;
    this.waiters = [];
    waiters.forEach((w) => w());
  }

  sendFrame(op, data) {
    const mask = crypto.randomBytes(4);
    const len = data.length;
    let header;
    if (len < 126) {
      header = Buffer.from([0x80 | op, 0x80 | len]);
    } else if (len < 65536) {
      header = Buffer.alloc(4); header[0] = 0x80 | op; header[1] = 0x80 | 126; header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10); header[0] = 0x80 | op; header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(len), 2);
    }
    const masked = Buffer.from(data);
    for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i % 4];
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  send(text) {
    this.sendFrame(0x1, Buffer.from(text, 'utf8'));
  }

  // Resolve with the first (not yet consumed) message matching `pred`.
  async next(pred, timeoutMs = 30000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const i = this.messages.findIndex(pred);
      if (i >= 0) return this.messages.splice(i, 1)[0];
      if (this.closed) throw new Error(`socket closed (${this.closed.code}) before a matching message`);
      const left = deadline - Date.now();
      if (left <= 0) throw new Error('timed out waiting for message');
      await new Promise((r) => { this.waiters.push(r); setTimeout(r, left); });
    }
  }

  close() {
    this.sendFrame(0x8, Buffer.from([0x03, 0xe8]));
    this.socket.end();
  }
}

function connectRaw(url) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = http.request({
      host: u.hostname,
      port: u.port,
      path: u.pathname + u.search,
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64'),
      },
    });
    req.on('upgrade', (res, socket, head) => resolve(new RawSocket(socket, head, res.headers)));
    req.on('response', (res) => reject(new Error(`websocket upgrade refused: HTTP ${res.statusCode}`)));
    req.on('error', reject);
    req.end();
  });
}

module.exports = { connectRaw };
