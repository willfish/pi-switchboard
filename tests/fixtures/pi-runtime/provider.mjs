import assert from 'node:assert/strict';
import { createServer } from 'node:http';

// Scripted OpenAI-compatible transport. All data is synthetic and stays local.
export async function provider() {
  const requests = [];
  const scripts = [];
  const held = new Set();
  const errors = [];
  const server = createServer(async (req, res) => {
    try {
      assert.equal(req.method, 'POST');
      assert.equal(req.url, '/v1/chat/completions');
      let body = '';
      for await (const chunk of req) {
        body += chunk;
        assert.ok(Buffer.byteLength(body) <= 2 * 1024 * 1024);
      }
      const payload = JSON.parse(body);
      requests.push(payload);
      const script = scripts.shift() ?? {};
      const reply = () => {
        held.delete(reply);
        if (res.destroyed) return;
        if (script.error) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: { message: script.error, type: 'invalid_request_error' } }));
          return;
        }
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        const chunk = (delta, finish_reason = null) => res.write(`data: ${JSON.stringify({
          id: 'fixture-completion', object: 'chat.completion.chunk', created: 1, model: payload.model,
          choices: [{ index: 0, delta, finish_reason }],
        })}\n\n`);
        if (script.tool) {
          chunk({ role: 'assistant', tool_calls: [{ index: 0, id: `fixture-tool-${requests.length}`, type: 'function',
            function: { name: script.tool.name, arguments: JSON.stringify(script.tool.arguments ?? {}) } }] });
          chunk({}, 'tool_calls');
        } else {
          chunk({ role: 'assistant', content: script.text ?? 'fixture response' });
          chunk({}, 'stop');
        }
        res.end('data: [DONE]\n\n');
      };
      if (script.hold) held.add(reply);
      else reply();
    } catch (error) {
      errors.push(String(error));
      res.writeHead(500); res.end('fixture error');
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    url: `http://127.0.0.1:${server.address().port}/v1`, requests, scripts, errors,
    get heldCount() { return held.size; },
    release() { for (const reply of [...held]) reply(); },
    async close() {
      for (const reply of [...held]) reply();
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
