"""Synthetic operator-network fixture. Never emit credentials or response bodies."""
import http.client
import json
from pathlib import Path
import secrets
import socket
import sys
from urllib.parse import urlsplit

TOKEN = Path('/run/pi-operator-fixture/token')


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def request(base, method, path, headers=(), body=None):
    url = urlsplit(base)
    conn = http.client.HTTPConnection(url.hostname, url.port, timeout=5)
    try:
        conn.putrequest(method, path)
        for name, value in headers:
            conn.putheader(name, value)
        if body is not None:
            conn.putheader('Content-Length', str(len(body)))
        conn.endheaders(body)
        reply = conn.getresponse()
        data = reply.read(1024 * 1024 + 1)
        check(len(data) <= 1024 * 1024, 'response exceeded fixture bound')
        return reply.status, dict(reply.getheaders()), data
    finally:
        conn.close()


def bootstrap(base):
    status, headers, body = request(base, 'POST', '/dashboard/api/v1/session',
        [('Origin', base), ('Content-Type', 'application/json')], b'{}')
    check(status == 200, 'automatic bootstrap failed')
    data = json.loads(body)
    check(set(data) == {'session'}, 'unexpected bootstrap schema')
    value = data['session']
    check(isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value),
          'invalid automatic session format')
    check(headers.get('cache-control') == 'no-store', 'missing no-store')
    check(not any(k.lower() == 'set-cookie' for k in headers), 'unexpected cookie')
    return value


def exercise(base):
    session = bootstrap(base)
    auth = [('X-Switchboard-Session', session)]
    status, _, body = request(base, 'GET', '/dashboard/api/v1/presence', auth)
    check(status == 200 and isinstance(json.loads(body).get('agents'), list), 'presence read failed')
    for headers in [auth, [('Authorization', 'Bearer ' + session)], [('Cookie', 'session=' + session)]]:
        check(request(base, 'GET', '/v1/agents', headers)[0] == 401, 'operator credential reached legacy authority')
    check(request(base, 'GET', '/dashboard/api/v1/presence', [('Cookie', 'session=' + session)])[0] == 401,
          'ambient cookie authenticated operator read')
    for origin in [None, 'null', 'http://foreign.invalid']:
        headers = [('Content-Type', 'application/json')]
        if origin is not None:
            headers.append(('Origin', origin))
        check(request(base, 'POST', '/dashboard/api/v1/session', headers, b'{}')[0] == 403,
              'invalid mutation origin admitted')
    check(request(base, 'POST', '/dashboard/api/v1/session',
          [('Origin', base), ('Content-Type', 'application/x-www-form-urlencoded')], b'x=1')[0] == 400,
          'form content admitted')
    check(request(base, 'POST', '/dashboard/api/v1/disconnect',
          auth + [('Origin', base), ('Content-Type', 'application/json')], b'{}')[0] == 204,
          'disconnect failed')
    check(request(base, 'GET', '/dashboard/api/v1/presence', auth)[0] == 401, 'invalidated session remained valid')
    print('PASS automatic session, exact Origin, no cookie authority, legacy isolation and disconnect')


def blocked(host, port):
    try:
        conn = socket.create_connection((host, port), timeout=2)
    except OSError:
        print('PASS prohibited route did not connect')
        return
    conn.close()
    raise RuntimeError('prohibited route reached the listener')


def native(base):
    token = TOKEN.read_text()
    check(request(base, 'GET', '/v1/agents', [('Authorization', 'Bearer ' + token)])[0] == 200,
          'native bearer read failed')
    for path in ['/dashboard/', '/dashboard/dashboard.js', '/dashboard/protocol.js']:
        status, _, body = request(base, 'GET', path)
        check(status == 200 and token.encode() not in body, 'static asset unavailable or contains credential')
    print('PASS native bearer retained and generic assets contain no relay token')


if __name__ == '__main__':
    action = sys.argv[1]
    if action == 'generate':
        TOKEN.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        TOKEN.write_text(secrets.token_hex(32))
        TOKEN.chmod(0o600)
    elif action == 'exercise':
        exercise(sys.argv[2])
    elif action == 'blocked':
        blocked(sys.argv[2], int(sys.argv[3]))
    elif action == 'native':
        native(sys.argv[2])
    else:
        raise RuntimeError('unknown fixture action')
