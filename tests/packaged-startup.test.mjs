import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';

// Complement retained-file/VM probes with syscall evidence from the ordinary
// packaged launcher. No -eval hook or production diagnostic endpoint is used.
test('Linux packaged startup makes no state writes or dependency network access', {
  skip: process.platform !== 'linux', timeout: 20000,
}, async t => {
  const executable = process.env.PI_AGENT_BUS_TEST_EXECUTABLE;
  const strace = process.env.PI_AGENT_BUS_TEST_STRACE;
  assert.ok(executable?.startsWith('/nix/store/'), 'supply the compiled hub artifact');
  assert.ok(strace?.startsWith('/nix/store/'), 'supply the pinned syscall tracer');
  const directory = await mkdtemp(join(tmpdir(), 'switchboard-startup-'));
  let cleanup = async () => {};
  t.after(async () => {
    try { await cleanup(); } finally { await rm(directory, { recursive: true, force: true }); }
  });
  const tokenFile = join(directory, 'token');
  const traceFile = join(directory, 'startup.trace');
  await writeFile(tokenFile, 'startup-fixture-token', { mode: 0o600, flag: 'wx' });
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise((resolve, reject) => reservation.close(e => e ? reject(e) : resolve()));
  const child = spawn(strace, ['-f', '--kill-on-exit', '-qq', '-y', '-s', '4096', '-o', traceFile,
    '-e', 'trace=%file,%network,%process,memfd_create,ftruncate,fchmod,fchown', executable], {
    detached: true, cwd: directory,
    env: { PATH: process.env.PATH, HOME: directory, TMPDIR: directory,
      PI_AGENT_BUS_BIND_HOST: '127.0.0.1', PI_AGENT_BUS_PORT: String(port),
      PI_AGENT_BUS_TOKEN_FILE: tokenFile, ERL_CRASH_DUMP: join(directory, 'forbidden.dump') },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let diagnostics = '';
  child.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-65536); });
  const exited = once(child, 'close');
  void exited.catch(() => {});
  const killOwnedDescendants = async () => {
    // Independent of tracer close: an escaped descendant may retain stderr.
    let trace = '';
    try { trace = await readFile(traceFile, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    const pids = new Set([...trace.matchAll(/^(\d+)\s/gm)].map(m => m[1]));
    for (const pid of pids) {
      try {
        const env = await readFile(`/proc/${pid}/environ`);
        if (env.includes(Buffer.from(`PI_AGENT_BUS_TOKEN_FILE=${tokenFile}\0`))) process.kill(Number(pid), 'SIGKILL');
      } catch (e) { if (!['ENOENT', 'ESRCH', 'EACCES'].includes(e.code)) throw e; }
    }
  };
  const waitForExit = async ms => {
    let timer;
    try {
      return await Promise.race([exited, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('traced process shutdown timed out')), ms);
      })]);
    } finally { clearTimeout(timer); }
  };
  let vmPid;
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      if (vmPid) {
        try { process.kill(vmPid, 'SIGTERM'); } catch (e) { if (e.code !== 'ESRCH') throw e; }
      } else child.kill('SIGKILL'); // invoke EXITKILL, not strace's graceful detach
    }
    try { return await waitForExit(5000); }
    catch (error) {
      // EXITKILL also covers tracees which changed process group or session.
      child.kill('SIGKILL');
      await killOwnedDescendants();
      try { return await waitForExit(2000); }
      catch {
        child.stderr.destroy();
        child.unref();
        throw error;
      }
    }
  };
  cleanup = async () => {
    try { await stop(); } finally { await killOwnedDescendants(); }
  };
  let healthy = false;
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline && child.exitCode === null && child.signalCode === null) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(300) });
      healthy = response.status === 200 && (await response.json()).ok === true;
      if (healthy) break;
    } catch { /* startup may not have bound its socket yet */ }
    await delay(25);
  }
  assert.ok(healthy, `traced packaged startup must serve health: ${diagnostics}`);
  const children = (await readFile(`/proc/${child.pid}/task/${child.pid}/children`, 'utf8')).trim().split(/\s+/);
  const vms = [];
  for (const pid of children) {
    try { if ((await readFile(`/proc/${pid}/comm`, 'utf8')).trim() === 'beam.smp') vms.push(Number(pid)); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  assert.equal(vms.length, 1, 'identify the actual VM beneath the tracer');
  [vmPid] = vms;
  // Signal the VM, not strace: keep observing through graceful shutdown.
  const [code, exitSignal] = await stop();
  assert.equal(code, 0, 'tracer must finish after the VM exits normally');
  assert.equal(exitSignal, null);
  const trace = await readFile(traceFile, 'utf8');
  assert.match(trace, /execve\(/, 'tracer must observe actual execution');
  assert.match(trace, /bind\(/, 'tracer must observe the listener');
  const mutations = /\b(?:creat|mkdir|mkdirat|rmdir|unlink|unlinkat|rename|renameat|renameat2|link|linkat|symlink|symlinkat|truncate|ftruncate|chmod|fchmod|fchmodat|chown|fchown|lchown|fchownat|utime|utimes|utimensat|mknod|mknodat)\(/;
  const boundPorts = new Map();
  for (const line of trace.split('\n')) {
    // BEAM's JIT sizes anonymous memfd-backed virtual memory, not disk state.
    const anonymousSizing = /\bftruncate\(\d+<\/memfd:vmem>\(deleted\),/.test(line);
    assert.ok(!mutations.test(line) || anonymousSizing, `unexpected filesystem mutation attempt: ${line}`);
    if (/\bopen(?:at|at2)?\(/.test(line) && /\bO_(?:WRONLY|RDWR|CREAT|TRUNC|APPEND|TMPFILE)\b/.test(line)) {
      // Shell/ERTS may probe the controlling terminal. Character-device IO
      // is not writable application state, unlike a regular file or cookie.
      assert.match(line, /"\/dev\/(?:null|tty)"/, `unexpected writable file open: ${line}`);
    }
    if (/\bconnect\(/.test(line)) {
      // libc may consult the host's local name-service cache during launch.
      // Permit only that fixed OS endpoint, not Internet sockets or proxies.
      assert.match(line, /sa_family=AF_UNIX, sun_path="\/(?:var\/)?run\/nscd\/socket"/,
        `unexpected dependency network connection attempt: ${line}`);
    }
    assert.ok(!/\bexecve(?:at)?\([^\n]*\/epmd"/.test(line), 'startup must not launch even a transient EPMD');
    // Runtime interface probes may open UDP sockets without transmitting.
    // Connected sends can only use an accepted stream or the fixed NSS socket.
    if (/\bsendto\(/.test(line)) assert.match(line, /, NULL, 0(?:\)|\s+<unfinished)/,
      `unexpected addressed network send: ${line}`);
    if (/\bsend(?:mmsg|msg)\(/.test(line)) {
      assert.match(line, /msg_name=NULL/, `unrecognized network send: ${line}`);
      assert.doesNotMatch(line, /msg_name=(?!NULL)/, `unexpected addressed network send: ${line}`);
    }
    if (/\bsocket\(AF_INET6?\b/.test(line)) assert.match(line, /SOCK_(?:STREAM|DGRAM)/,
      'unexpected raw network socket');
    if (/\bbind\(/.test(line)) {
      assert.match(line, /sa_family=AF_INET,/, `unexpected listener family: ${line}`);
      const inode = /\bbind\(\d+<socket:\[(\d+)\]>/.exec(line)?.[1];
      const bound = /sin_port=htons\((\d+)\)/.exec(line)?.[1];
      assert.ok(inode && (Number(bound) === port || bound === '0'), `unexpected socket bind: ${line}`);
      const address = /sin_addr=inet_addr\("([^"]+)"\)/.exec(line)?.[1];
      if (Number(bound) === port) assert.equal(address, '127.0.0.1', 'configured listener must bind loopback');
      boundPorts.set(inode, { port: Number(bound), address });
    }
    if (/\blisten\(/.test(line)) {
      const inode = /\blisten\(\d+<socket:\[(\d+)\]>/.exec(line)?.[1];
      assert.deepEqual(boundPorts.get(inode), { port, address: '127.0.0.1' },
        `unexpected transient listener: ${line}`);
    }
  }
});
