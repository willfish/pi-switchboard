"""Synthetic guest-only checks. Never emit credentials, HTTP bodies or journal text."""

import errno
import http.client
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import time
import traceback
import uuid


ROOT = Path('/run/pi-bus-fixture')
TOKEN = ROOT / 'token$literal'
UNIT = 'pi-agent-bus.service'
STAGE = 'initialization'
IDS = [str(uuid.UUID(int=n, version=4)) for n in range(1, 6)]
STREAM_IDS = IDS[1:-1]
OFFLINE_ID = IDS[-1]


class CheckFailure(Exception):
    """Only fixed, public fixture diagnostics belong in this exception."""


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


def run(*args, timeout=10):
    result = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
    require(result.returncode == 0, 'guest command failed')
    return result.stdout.decode()


def properties(*names):
    text = run('systemctl', 'show', UNIT, *['--property=' + n for n in names])
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)


def main_pid():
    return int(properties('MainPID')['MainPID'])


def token():
    return TOKEN.read_text()


def markers():
    return json.loads((ROOT / 'markers.json').read_text())


def generate():
    ROOT.mkdir(mode=0o700)
    os.chmod(ROOT, 0o700)
    for name, value in {
        TOKEN.name: secrets.token_hex(32),
        'markers.json': json.dumps({key: secrets.token_hex(24) for key in ('body', 'presence', 'malformed')}),
    }.items():
        fd = os.open(ROOT / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(value)
    Path('/root/pi-bus-inaccessible').mkdir(mode=0o700)


def request(method, route, body=None, auth=True):
    connection = http.client.HTTPConnection('127.0.0.1', 7420, timeout=3)
    headers = {'Content-Type': 'application/json'}
    if auth:
        headers['Authorization'] = 'Bearer ' + token()
    encoded = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
    try:
        connection.request(method, route, encoded, headers)
        response = connection.getresponse()
        payload = response.read(1024 * 1024 + 1)
        require(len(payload) <= 1024 * 1024, 'oversized response')
        return response.status, payload
    finally:
        connection.close()


def ready(previous_pid=None):
    end = time.monotonic() + 12
    while time.monotonic() < end:
        try:
            pid = main_pid()
            if pid and pid != previous_pid and request('GET', '/health', auth=False)[0] == 200:
                return pid
        except (OSError, http.client.HTTPException, CheckFailure):
            pass
        time.sleep(0.1)
    raise CheckFailure('service did not become healthy')


def discovery():
    status, body = request('GET', '/v1/agents')
    require(status == 200, 'discovery failed')
    page = json.loads(body)
    require(page['nextCursor'] is None, 'unexpected discovery pagination')
    return page


def register():
    for agent_id in IDS:
        agent = {
            'agentId': agent_id, 'sessionId': IDS[0], 'host': 'synthetic-vm',
            'cwd': '/synthetic-vm', 'sessionName': 'synthetic-vm',
            'label': markers()['presence'], 'model': None, 'status': 'idle',
            'pid': 1, 'acceptsControl': False,
        }
        require(request('PUT', '/v1/agents/' + agent_id, agent)[0] == 204, 'registration failed')


class Events:
    def __init__(self, agent_id=IDS[1]):
        self.connection = http.client.HTTPConnection('127.0.0.1', 7420, timeout=3)
        self.connection.request('GET', '/v1/events?agentId=' + agent_id, headers={
            'Authorization': 'Bearer ' + token(),
        })
        self.response = self.connection.getresponse()
        require(self.response.status == 200, 'SSE admission failed')
        require(self.response.getheader('content-type') == 'text/event-stream', 'SSE content type')

    def event(self, wanted):
        end = time.monotonic() + 5
        size = 0
        event_type = None
        data = []
        while time.monotonic() < end:
            line = self.response.readline(1024 * 1024 + 1)
            require(line, 'premature SSE EOF')
            size += len(line)
            require(size <= 1024 * 1024, 'oversized SSE frame')
            if line in (b'\n', b'\r\n'):
                if data:
                    payload = json.loads(b'\n'.join(data))
                    if wanted == 'message' and event_type == 'presence_delta':
                        # Other clients attaching/detaching changes receiving
                        # presence while these independent streams stay open.
                        require(isinstance(payload.get('changes'), list)
                                and isinstance(payload.get('caughtUp'), bool)
                                and all(key in payload for key in ('epoch', 'fromRevision', 'toRevision')),
                                'invalid interleaved presence delta')
                        data, event_type, size = [], None, 0
                        continue
                    require(event_type == wanted, 'unexpected SSE event')
                    return payload
                size = 0
            elif line.startswith(b'event: '):
                event_type = line[7:].strip().decode()
            elif line.startswith(b'data: '):
                data.append(line[6:].rstrip(b'\r\n'))
        raise CheckFailure('SSE event deadline')

    def initial(self, page):
        snapshot = self.event('presence_snapshot')
        require(snapshot['final'] and snapshot['chunk'] == 0 and snapshot['total'] == len(IDS), 'snapshot shape')
        require(snapshot['epoch'] == page['epoch'], 'snapshot epoch')
        require([a['agentId'] for a in snapshot['agents']] == IDS, 'snapshot population')
        revision = snapshot['revision']
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            caught = self.event('presence_delta')
            require(caught['epoch'] == snapshot['epoch'] and caught['fromRevision'] == revision,
                    'caught-up revision continuity')
            require(isinstance(caught['changes'], list) and isinstance(caught['caughtUp'], bool),
                    'caught-up boundary schema')
            revision = caught['toRevision']
            if caught['caughtUp']:
                return
        raise CheckFailure('caught-up boundary deadline')

    def ended(self):
        end = time.monotonic() + 3
        total = 0
        try:
            while time.monotonic() < end:
                chunk = self.response.read(4096)
                if not chunk:
                    return
                total += len(chunk)
                require(total < 1024 * 1024, 'old stream did not end')
        except (ConnectionResetError, http.client.IncompleteRead, http.client.RemoteDisconnected):
            return
        finally:
            self.connection.close()
        raise CheckFailure('old stream remained connected')


def message(recipient):
    return {'id': str(uuid.uuid4()), 'from': IDS[0], 'to': recipient,
            'kind': 'notice', 'body': markers()['body']}


def workload():
    register()
    page = discovery()
    require([a['agentId'] for a in page['agents']] == IDS, 'discovery population')
    # Keep three independent, admitted SSE sockets open through shutdown.
    events = []
    for agent_id in STREAM_IDS:
        stream = Events(agent_id)
        stream.initial(page)
        events.append(stream)
        notice = message(agent_id)
        status, payload = request('POST', '/v1/messages', notice)
        require(status == 202 and json.loads(payload)['state'] == 'accepted', 'notice acceptance')
        delivered = stream.event('message')
        require(delivered['id'] == notice['id'] and delivered['body'] == notice['body'], 'notice delivery')
    # A separate registered recipient has no SSE consumer, so this stays queued.
    queued = message(OFFLINE_ID)
    status, payload = request('POST', '/v1/messages', queued)
    require(status == 202 and json.loads(payload)['state'] == 'accepted', 'queued-mail acceptance')
    return events, queued, page['epoch']


def authorization_and_malformed():
    routes = [('GET', '/v1/agents'), ('PUT', '/v1/agents/' + IDS[0]),
              ('DELETE', '/v1/agents/' + IDS[0]), ('POST', '/v1/messages'),
              ('GET', '/v1/events?agentId=' + IDS[0])]
    for method, route in routes:
        require(request(method, route, auth=False)[0] == 401, 'route admitted without authorization')
    require(request('GET', '/health', auth=False)[0] == 200, 'public health failed')
    malformed = ('{"fixture":"' + markers()['malformed']).encode()
    require(request('POST', '/v1/messages', malformed)[0] == 400, 'malformed input status')


def scan_logs():
    journal = run('journalctl', '--unit=' + UNIT, '--no-pager', '--output=cat').encode()
    forbidden = [token(), *markers().values()]
    require(not any(value.encode() in journal for value in forbidden), 'sensitive content found in journal')


def access_probe(package, credential_path, uid, gid):
    # Called inside the actual service mount namespace, with its dynamic UID/GID.
    require(os.getuid() == uid and os.getgid() == gid, 'probe identity')
    require(bool(Path(credential_path).read_bytes()), 'loaded credential unreadable to dynamic identity')
    for path in (TOKEN, Path('/root/pi-bus-inaccessible')):
        try:
            if path == TOKEN:
                with path.open('rb'):
                    pass
            else:
                list(path.iterdir())
        except PermissionError:
            continue
        raise CheckFailure('protected path accessible to dynamic identity')
    try:
        fd = os.open(Path(package) / 'forbidden-vm-write', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except (PermissionError, OSError) as error:
        require(error.errno in (13, 30), 'unexpected release write failure')
    else:
        os.close(fd)
        os.unlink(Path(package) / 'forbidden-vm-write')
        raise CheckFailure('release was writable')


def inspect_runtime(bind, package):
    pid = main_pid()
    proc = Path('/proc') / str(pid)
    status = dict(line.split(':', 1) for line in (proc / 'status').read_text().splitlines() if ':' in line)
    uid = int(status['Uid'].split()[0])
    gid = int(status['Gid'].split()[0])
    require(uid != 0 and uid == int(run('id', '-u', 'pi-agent-bus')), 'dynamic UID')
    require(stat.S_IMODE(TOKEN.stat().st_mode) == 0o600, 'original token permissions')
    require(TOKEN.stat().st_uid == 0 and ROOT.stat().st_uid == 0, 'original token owner')
    require(stat.S_IMODE(ROOT.stat().st_mode) == 0o700, 'token directory permissions')
    env = dict(item.split(b'=', 1) for item in (proc / 'environ').read_bytes().split(b'\0') if b'=' in item)
    require(env[b'HOME'] == b'/root/pi-bus-inaccessible', 'effective HOME')
    require(env[b'ERL_CRASH_DUMP'] == b'/dev/null', 'effective crash dump suppression')
    require(env[b'PI_AGENT_BUS_BIND_HOST'].decode() == bind, 'effective bind address')
    credential_path = env[b'PI_AGENT_BUS_TOKEN_FILE'].decode()
    require(credential_path.startswith('/run/credentials/') and credential_path.endswith('/bus-token'), 'credential indirection')
    require(token().encode() not in b'\0'.join(env.values()), 'token appeared in environment')
    require(b'/no-fixture-path' in env[b'PATH'], 'minimal input PATH not retained')
    require(b'/run/current-system/sw' not in env[b'PATH'], 'launcher depended on global PATH')
    args = (proc / 'cmdline').read_bytes().split(b'\0')
    require(not any(arg in args for arg in (b'-name', b'-sname', b'-setcookie', b'-remsh')), 'distributed VM arguments')
    require(args[args.index(b'-start_epmd') + 1] == b'false', 'EPMD suppression')
    run('nsenter', '--target', str(pid), '--mount', '--',
        'setpriv', '--reuid=' + str(uid), '--regid=' + str(gid), '--clear-groups',
        sys.executable, __file__, 'access', package, credential_path, str(uid), str(gid))
    inodes = set()
    fds = list((proc / 'fd').iterdir())
    for fd in fds:
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        match = re.fullmatch(r'socket:\[(\d+)\]', target)
        if match:
            inodes.add(match[1])
    listeners = []
    for family in ('tcp', 'tcp6'):
        for line in (proc / 'net' / family).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == '0A' and fields[9] in inodes:
                listeners.append((family, fields[1]))
    expected_address = '0100007F' if bind == '127.0.0.1' else '00000000'
    require(listeners == [('tcp', expected_address + ':1CFC')], 'unexpected relay listener')
    for process in Path('/proc').iterdir():
        if process.name.isdigit():
            try:
                require((process / 'comm').read_text().strip() != 'epmd', 'retained EPMD process')
            except FileNotFoundError:
                pass
    effective = properties('DynamicUser', 'ProtectSystem', 'ProtectHome', 'PrivateTmp',
                           'NoNewPrivileges', 'RuntimeDirectory', 'Restart', 'RestartUSec',
                           'TimeoutStopUSec', 'KillMode', 'KillSignal', 'LimitCORE',
                           'RestrictAddressFamilies', 'CPUAccounting', 'MemoryAccounting', 'TasksAccounting',
                           'MemoryCurrent', 'MemoryPeak', 'TasksCurrent', 'TasksPeak', 'CPUUsageNSec',
                           'MemoryMax', 'MemoryHigh', 'TasksMax', 'LimitNOFILE', 'LimitNOFILESoft')
    for key in ('DynamicUser', 'PrivateTmp', 'NoNewPrivileges', 'MemoryAccounting', 'TasksAccounting'):
        require(effective[key] == 'yes', 'effective boolean hardening')
    # systemd 260 removed CPUAccounting=: CPU accounting is now unconditional.
    require(0 < int(effective['CPUUsageNSec']) < 2**64 - 1, 'effective CPU accounting missing')
    cgroup = properties('ControlGroup')['ControlGroup']
    cpu_stats = dict(line.split() for line in (Path('/sys/fs/cgroup' + cgroup) / 'cpu.stat').read_text().splitlines())
    require(int(cpu_stats['usage_usec']) > 0, 'cgroup CPU accounting missing')
    require(effective['ProtectSystem'] == 'strict' and effective['ProtectHome'] == 'yes', 'effective filesystem protection')
    require(effective['LimitCORE'] == '0' and effective['KillMode'] == 'control-group' and effective['KillSignal'] == '15', 'effective shutdown limits')
    require(effective['TimeoutStopUSec'] == '10s' and effective['RestartUSec'] == '2s', 'effective operational deadlines')
    require(effective['MemoryMax'] == 'infinity' and effective['MemoryHigh'] == 'infinity', 'unexpected fixture memory quota')
    require(set(effective['RestrictAddressFamilies'].split()) == {'AF_UNIX', 'AF_INET', 'AF_INET6', 'AF_NETLINK'}, 'effective address families')
    # Only this explicit public-property allowlist is printed, never full show/env.
    print(json.dumps({'effective': effective, 'fds': len(fds), 'threads': int(status['Threads'])}, sort_keys=True))
    print('inherited manager limits: ' + run('systemctl', 'show', '--property=DefaultLimitNOFILE', '--property=DefaultTasksMax').strip())
    print('effective process limits:\n' + (proc / 'limits').read_text())
    scan_artifacts()


def scan_artifacts():
    roots = [Path('/root'), Path('/home'), Path('/tmp'), Path('/var/tmp'), Path('/run/pi-agent-bus')]
    for root in roots:
        if root.exists():
            for item in root.rglob('*'):
                require(item.name not in ('.erlang.cookie', 'erl_crash.dump', 'forbidden-vm-write'), 'retained runtime artifact')
    runtime = Path('/run/pi-agent-bus')
    require(not runtime.exists() or not list(runtime.iterdir()), 'unexpected relay runtime state')
    cores = Path('/var/lib/systemd/coredump')
    require(not cores.exists() or not list(cores.iterdir()), 'retained system core dump')


def stop(events=None):
    before = main_pid()
    started = time.monotonic()
    run('systemctl', 'stop', UNIT, timeout=8)
    elapsed = time.monotonic() - started
    require(elapsed < 5, 'ordinary shutdown exceeded five seconds')
    result = properties('Result', 'ExecMainCode', 'ExecMainStatus', 'MainPID')
    require(result == {'Result': 'success', 'ExecMainCode': '1', 'ExecMainStatus': '0', 'MainPID': '0'}, 'shutdown required signal escalation')
    require(not Path('/proc', str(before)).exists(), 'old main process remained')
    for stream in events or []:
        stream.ended()
    print('ordinary shutdown seconds: ' + format(elapsed, '.3f'))
    scan_logs()
    scan_artifacts()


def empty_after_restart(queued, epoch):
    page = discovery()
    require(page['agents'] == [] and page['epoch'] != epoch, 'volatile registration state retained')
    require(request('POST', '/v1/messages', queued)[0] == 404, 'old dedup acceptance retained')
    require(request('GET', '/v1/events?agentId=' + IDS[1])[0] == 404, 'old registration retained')
    register()
    events = Events(OFFLINE_ID)
    events.initial(discovery())
    fresh = message(OFFLINE_ID)
    require(request('POST', '/v1/messages', fresh)[0] == 202, 'fresh mailbox acceptance failed')
    require(events.event('message')['id'] == fresh['id'], 'old queued mail survived restart')
    events.connection.close()


def exercise(bind, package):
    global STAGE
    STAGE = 'authorization and malformed requests'
    ready()
    authorization_and_malformed()
    STAGE = 'initial workload and effective isolation'
    events, queued, epoch = workload()
    inspect_runtime(bind, package)
    STAGE = 'active-stream queued-mail ordinary stop'
    stop(events)
    STAGE = 'explicit start and volatile loss'
    run('systemctl', 'start', UNIT)
    ready()
    empty_after_restart(queued, epoch)
    STAGE = 'fresh registration and automatic main-process failure recovery'
    events, queued, epoch = workload()
    before = main_pid()
    restarts = int(properties('NRestarts')['NRestarts'])
    os.kill(before, signal.SIGABRT)
    ready(previous_pid=before)
    for stream in events:
        stream.ended()
    require(int(properties('NRestarts')['NRestarts']) > restarts, 'automatic restart not observed')
    empty_after_restart(queued, epoch)
    STAGE = 'post-failure fresh registration and isolation'
    events, _, _ = workload()
    inspect_runtime(bind, package)
    scan_logs()
    for stream in events:
        stream.connection.close()


class Connectivity(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'synthetic-connectivity')

    def log_message(self, *_args):
        pass


def peer(host):
    connection = http.client.HTTPConnection(host, 8080, timeout=3)
    connection.request('GET', '/')
    response = connection.getresponse()
    require(response.status == 200 and response.read() == b'synthetic-connectivity', 'independent peer connectivity failed')
    connection.close()
    # TCP admission must fail, even for the public health route. An HTTP reset
    # after successful connect is not firewall-denial evidence.
    try:
        admitted = socket.create_connection((host, 7420), timeout=2)
    except OSError as error:
        require(error.errno in (errno.ECONNREFUSED, errno.EHOSTUNREACH, errno.ETIMEDOUT)
                or isinstance(error, TimeoutError), 'unexpected peer network error')
    else:
        admitted.close()
        raise CheckFailure('untrusted peer reached relay TCP listener')
    connection = http.client.HTTPConnection(host, 8080, timeout=3)
    connection.request('GET', '/')
    response = connection.getresponse()
    require(response.status == 200 and response.read() == b'synthetic-connectivity', 'peer connectivity lost during denial test')
    connection.close()


def main():
    global STAGE
    mode = sys.argv[1]
    STAGE = mode
    if mode == 'generate':
        generate()
    elif mode == 'connectivity':
        http.server.HTTPServer(('0.0.0.0', 8080), Connectivity).serve_forever()
    elif mode == 'peer':
        peer(sys.argv[2])
    elif mode == 'exercise':
        exercise(*sys.argv[2:])
    elif mode == 'access':
        access_probe(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]))
    elif mode == 'final-stop':
        stop()
    else:
        raise CheckFailure('unknown fixture mode')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Exception repr/tracebacks can contain HTTP bodies or command output.
        # Our assertion messages are fixed strings, never response-derived.
        detail = str(error) if type(error) is CheckFailure else type(error).__name__
        location = ','.join(str(frame.lineno) for frame in traceback.extract_tb(error.__traceback__))
        print('hardened-service fixture failed during ' + STAGE + ': ' + detail + ' at lines ' + location, file=sys.stderr)
        sys.exit(1)
