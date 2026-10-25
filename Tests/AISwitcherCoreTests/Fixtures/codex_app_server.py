"""Disposable stdio fixture. No network or real credentials."""
import json
import os
from pathlib import Path
import sys
import time

home = Path(os.environ['CODEX_HOME'])
mode = home.name


def emit(value):
    line = json.dumps(value) + '\n'
    if mode == 'fragmented':
        for index in range(0, len(line), 7):
            sys.stdout.write(line[index:index + 7])
            sys.stdout.flush()
            time.sleep(0.001)
    else:
        print(line, end='', flush=True)


for line in sys.stdin:
    message = json.loads(line)
    method = message['method']
    with (home / 'methods.txt').open('a') as log:
        log.write(method + '\n')
    if 'id' not in message:
        continue
    result = {}
    if method == 'initialize':
        assert 'OPENAI_API_KEY' not in os.environ
        assert 'CODEX_API_KEY' not in os.environ
    elif method == 'account/read':
        result = {'account': None if mode == 'unauthed' else {'type': 'chatgpt', 'email': mode + '@example.test', 'planType': 'plus'}}
    elif method == 'account/rateLimits/read':
        if mode == 'timeout':
            continue
        if mode == 'exit':
            sys.exit(0)
        if mode == 'error':
            emit({'id': message['id'], 'error': {'code': -32001, 'message': 'private-detail-do-not-display'}})
            continue
        result = {'accountId': mode, 'rateLimits': {'limitId': 'codex', 'primary': {'usedPercent': 23, 'windowDurationMins': 300, 'resetsAt': 2000000000}}}
    elif method == 'account/login/start':
        # Deliberately deliver the completion before its request response.
        emit({'method': 'account/login/completed', 'params': {'loginId': 'fixture-login', 'success': True}})
        result = {'type': 'chatgpt', 'loginId': 'fixture-login', 'authUrl': 'https://auth.openai.com/authorize?fixture=true'}
    elif method not in ['account/login/cancel', 'account/logout']:
        emit({'id': message['id'], 'error': {'code': -32601, 'message': 'unknown method'}})
        continue
    emit({'id': message['id'], 'result': result})
