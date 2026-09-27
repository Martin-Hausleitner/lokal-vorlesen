#!/usr/bin/env python3
"""Persistent, private stdin/stdout Piper worker for the native player.

The worker loads one voice once, accepts one synthesis request at a time, and
keeps its protocol deliberately small. Requests are newline-delimited JSON
with a ``command`` discriminator; responses are newline-delimited JSON with
an ``event`` discriminator. No socket or network endpoint is involved.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import sys
import threading
import time

# The worker also runs from signed application Resources. Never add bytecode there.
sys.dont_write_bytecode = True

from synthesize import (SynthesisCancelled, load_voice, stream_to_directory,
                        validate_text)


def write_event(lock, event, **fields):
    payload = {'event': event}
    payload.update(fields)
    with lock:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + '\n')
        sys.stdout.flush()


def remove_stream_directory(directory):
    if directory:
        shutil.rmtree(Path(directory), ignore_errors=True)


def reader(commands):
    for line in sys.stdin:
        try:
            value = json.loads(line)
        except (TypeError, ValueError):
            commands.put({'command': '__invalid__'})
            continue
        commands.put(value if isinstance(value, dict) else {'command': '__invalid__'})
    commands.put({'command': '__eof__'})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--speaker', type=int, default=0)
    parser.add_argument('--idle-timeout', type=float, default=300.0)
    args = parser.parse_args()
    if args.idle_timeout <= 0:
        parser.error('--idle-timeout must be positive')

    try:
        voice = load_voice(args.model)
    except Exception:
        # Do not expose model paths, URLs, or runtime details through the
        # private protocol. The parent can report a generic engine failure.
        return 2

    commands = queue.Queue()
    output_lock = threading.Lock()
    command_reader = threading.Thread(target=reader, args=(commands,), daemon=True)
    command_reader.start()
    write_event(output_lock, 'ready', pid=os.getpid(), model=str(args.model),
                idle_timeout=args.idle_timeout)

    active = None
    last_activity = time.monotonic()
    shutting_down = False

    while not shutting_down:
        timeout = max(0.05, args.idle_timeout - (time.monotonic() - last_activity))
        try:
            command = commands.get(timeout=timeout)
        except queue.Empty:
            if active is None and time.monotonic() - last_activity >= args.idle_timeout:
                write_event(output_lock, 'idle_timeout')
                return 0
            continue

        name = command.get('command')
        if name == '__eof__':
            shutting_down = True
            if active is not None:
                active['cancel'].set()
            continue
        if name == '__invalid__':
            write_event(output_lock, 'error', error='Ungültige Worker-Anfrage.')
            continue
        last_activity = time.monotonic()

        if name == 'cancel':
            if active is not None and command.get('request_id') == active['request_id']:
                active['cancel_requested'] = True
                active['cancel'].set()
            continue

        if name != 'synthesize':
            write_event(output_lock, 'error', error='Unbekannter Worker-Befehl.')
            continue
        if active is not None:
            write_event(output_lock, 'error', request_id=command.get('request_id'),
                        error='Worker ist bereits beschäftigt.')
            continue

        request_id = command.get('request_id')
        text = command.get('text')
        directory = command.get('stream_directory')
        output = command.get('output')
        if not isinstance(request_id, str) or not request_id or not isinstance(text, str):
            write_event(output_lock, 'error', request_id=request_id,
                        error='Ungültige Syntheseanfrage.')
            continue
        if not isinstance(directory, str) or not directory:
            write_event(output_lock, 'error', request_id=request_id,
                        error='Ungültiger Audiopuffer.')
            continue
        try:
            validate_text(text)
            speaker = int(command.get('speaker', args.speaker))
            if speaker < 0 or speaker > 1000:
                raise ValueError('Ungültige Stimme.')
        except (TypeError, ValueError):
            write_event(output_lock, 'error', request_id=request_id,
                        error='Ungültige Syntheseanfrage.')
            continue

        cancel = threading.Event()
        active = {'request_id': request_id, 'cancel': cancel,
                  'cancel_requested': False}
        write_event(output_lock, 'started', request_id=request_id)

        def on_chunk(count, request_id=request_id):
            write_event(output_lock, 'chunk', request_id=request_id, count=count)

        def synthesize_request():
            try:
                stream_to_directory(text, voice, speaker, directory, cancel, on_chunk)
                commands.put({'command': '__finished__', 'request_id': request_id,
                              'directory': directory, 'output': output})
            except SynthesisCancelled:
                remove_stream_directory(directory)
                commands.put({'command': '__cancelled__', 'request_id': request_id,
                              'directory': directory})
            except Exception:
                remove_stream_directory(directory)
                commands.put({'command': '__failed__', 'request_id': request_id,
                              'directory': directory})

        threading.Thread(target=synthesize_request, daemon=True).start()

        while active is not None:
            try:
                result = commands.get(timeout=0.05)
            except queue.Empty:
                continue
            result_name = result.get('command')
            if result_name == 'cancel':
                if result.get('request_id') == request_id:
                    active['cancel_requested'] = True
                    cancel.set()
                continue
            if result_name == 'synthesize':
                write_event(output_lock, 'error', request_id=result.get('request_id'),
                            error='Worker ist bereits beschäftigt.')
                continue
            if result_name == '__finished__':
                if result.get('request_id') == request_id:
                    if active['cancel_requested']:
                        remove_stream_directory(directory)
                        write_event(output_lock, 'cancelled', request_id=request_id)
                    else:
                        write_event(output_lock, 'done', request_id=request_id)
                    active = None
                    last_activity = time.monotonic()
                continue
            if result_name == '__cancelled__':
                if result.get('request_id') == request_id:
                    write_event(output_lock, 'cancelled', request_id=request_id)
                    active = None
                    last_activity = time.monotonic()
                continue
            if result_name == '__failed__':
                if result.get('request_id') == request_id:
                    write_event(output_lock, 'error', request_id=request_id,
                                error='Audio konnte nicht erzeugt werden.')
                    active = None
                    last_activity = time.monotonic()
                continue
            if result_name == '__eof__':
                active['cancel_requested'] = True
                cancel.set()
                shutting_down = True
                continue

    if active is not None:
        active['cancel'].set()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
