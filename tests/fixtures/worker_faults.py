"""Isolated subprocess faults; never loads a model or accesses user state."""
import json
import os
import sys
import time

mode = sys.argv[sys.argv.index('--model') + 1]
request = json.loads(sys.stdin.readline())
if mode == 'malformed':
    print('{broken-json', flush=True)
    time.sleep(20)
elif mode == 'truncated':
    sys.stdout.write('{"event":')
    sys.stdout.flush()
elif mode == 'exit':
    os._exit(9)
elif mode == 'closed-output':
    os.close(1)
    time.sleep(20)
elif mode == 'oversized':
    sys.stdout.write('x' * (1024 * 1024 + 1))
    sys.stdout.flush()
    time.sleep(20)
elif mode == 'stale':
    first = request['request_id']
    print(json.dumps({'event': 'done', 'request_id': first}), flush=True)
    request = json.loads(sys.stdin.readline())
    print(json.dumps({'event': 'error', 'request_id': first}), flush=True)
    time.sleep(.2)
    print(json.dumps({'event': 'done', 'request_id': request['request_id']}), flush=True)
    time.sleep(20)
