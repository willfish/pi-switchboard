import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';

// Real loopback HTTP transport. Holding a response does not undo its upstream
// effects. Native downstream aborts are recorded, never replaced by mock promises.
export async function responseProxy(target) {
  assert.equal(new URL(target).hostname, '127.0.0.1');
  const records = [];
  const gates = [];
  const upstreams = new Set();
  const errors = [];
  const server = createServer(async (req, res) => {
    const record = { method: req.method, path: req.url, body: '', hold: false,
      chunks: [], bytes: 0, ended: false, closed: false, releaseBoundary: undefined };
    records.push(record);
    res.on('close', () => { record.closed = true; });
    try {
      for await (const chunk of req) {
        record.body += chunk;
        assert.ok(Buffer.byteLength(record.body) <= 2 * 1024 * 1024);
      }
      const gate = gates.findIndex(match => match(record));
      if (gate >= 0) { gates.splice(gate, 1); record.hold = true; }
      let status; let headers; let sentHeaders = false;
      const flush = () => {
        if (record.hold || res.destroyed || status === undefined) return;
        if (!sentHeaders) { res.writeHead(status, headers); res.flushHeaders(); sentHeaders = true; }
        for (const chunk of record.chunks.splice(0)) res.write(chunk);
        record.bytes = 0;
        if (record.ended) res.end();
      };
      record.release = () => {
        record.releaseBoundary = res.destroyed ? 'downstream-already-closed' : 'downstream-open';
        record.hold = false; flush();
      };
      const upstream = request(new URL(req.url, target), { method: req.method,
        headers: { ...req.headers, host: new URL(target).host }, timeout: 30000 }, response => {
        status = response.statusCode; headers = response.headers;
        record.status = status;
        response.on('data', chunk => {
          record.bytes += chunk.length;
          if (record.bytes > 2 * 1024 * 1024) {
            errors.push('proxy held response exceeded bound'); upstream.destroy(); return;
          }
          record.chunks.push(chunk); flush();
        });
        response.on('end', () => { record.ended = true; flush(); });
        response.on('error', error => { if (!res.destroyed) res.destroy(error); });
        flush();
      });
      upstreams.add(upstream);
      upstream.on('close', () => upstreams.delete(upstream));
      upstream.on('timeout', () => upstream.destroy());
      upstream.on('error', error => { if (!res.destroyed) res.destroy(error); });
      upstream.end(record.body);
    } catch (error) { errors.push(String(error)); res.destroy(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`, records, gates, errors,
    async close() {
      for (const upstream of upstreams) upstream.destroy();
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
