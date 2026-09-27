#!/usr/bin/env python3
"""Offline Piper synthesis and the one-shot CLI used by LokalVorlesen.

The file-writing helpers are also used by ``tts_worker.py``. Keeping the
streaming implementation here makes the persistent backend obey the same
chunk and status-file contract as the original one-shot process.
"""
import argparse
import json
import os
import re
from pathlib import Path
import sys
import wave


class SynthesisCancelled(Exception):
    """The caller cancelled a request between streamed audio chunks."""


def validate_text(text):
    if not text.strip() or len(text) > 100000:
        raise ValueError('Text must contain 1–100000 characters.')


def validate_model(model):
    model = Path(model)
    if not model.is_file() or not Path(str(model) + '.json').is_file():
        raise ValueError('Local voice model is missing.')
    return model


def load_voice(model):
    """Load one Piper voice, without downloading any runtime assets."""
    model = validate_model(model)
    # German eSpeak phonemes require no network or auto-downloaded resources.
    from piper import PiperVoice
    from piper.config import PiperConfig
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    config = PiperConfig.from_dict(json.loads(
        Path(str(model) + '.json').read_text(encoding='utf-8')))

    class GermanVoice(PiperVoice):
        def phonemize(self, value):
            # Piper 1.8 emits decomposed c + cedilla; this model was trained
            # with the precomposed IPA ç for the German "ich" sound.
            return [list(''.join(sentence).replace('c\u0327', 'ç'))
                    for sentence in super().phonemize(value)]

    return GermanVoice(ort.InferenceSession(str(model), sess_options=options,
                       providers=['CPUExecutionProvider']), config,
                       use_tashkeel=False)


def _check_cancel(cancel_event):
    if cancel_event is not None and cancel_event.is_set():
        raise SynthesisCancelled()


def _atomic_status(directory, count, done):
    temporary = directory / 'status.next'
    temporary.write_text(json.dumps({'count': count, 'done': done}), encoding='utf-8')
    os.replace(temporary, directory / 'status.json')


def stream_to_directory(text, voice, speaker, directory, cancel_event=None,
                        on_chunk=None):
    """Write the existing atomic ``chunk-*.wav``/``status.json`` stream."""
    from piper.config import SynthesisConfig

    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    count = 0

    _check_cancel(cancel_event)
    _atomic_status(directory, count, False)
    # Small first phrase starts playback quickly; later phrases fill the buffer.
    for sentence in re.split(r'(?<=[.!?])\s+|\n+', text):
        remaining = sentence.strip()
        while remaining:
            _check_cancel(cancel_event)
            limit = 55 if count == 0 else 280
            if len(remaining) > limit:
                cut = remaining.rfind(' ', 0, limit + 1)
                cut = cut if cut > 0 else limit
                part, remaining = remaining[:cut], remaining[cut:].lstrip()
            else:
                part, remaining = remaining, ''
            for chunk in voice.synthesize(part, SynthesisConfig(speaker_id=speaker)):
                _check_cancel(cancel_event)
                temporary = directory / f'chunk-{count:05d}.next'
                metadata_temporary = directory / f'chunk-{count:05d}.json.next'
                try:
                    with wave.open(str(temporary), 'wb') as wav:
                        wav.setnchannels(chunk.sample_channels)
                        wav.setsampwidth(chunk.sample_width)
                        wav.setframerate(chunk.sample_rate)
                        wav.writeframes(chunk.audio_int16_bytes)
                    os.chmod(temporary, 0o600)
                    _check_cancel(cancel_event)
                    metadata_temporary.write_text(
                        json.dumps({'text': part}, ensure_ascii=False), encoding='utf-8')
                    os.chmod(metadata_temporary, 0o600)
                    os.replace(metadata_temporary,
                               directory / f'chunk-{count:05d}.json')
                    _check_cancel(cancel_event)
                    os.replace(temporary, directory / f'chunk-{count:05d}.wav')
                except BaseException:
                    temporary.unlink(missing_ok=True)
                    metadata_temporary.unlink(missing_ok=True)
                    raise
                count += 1
                _atomic_status(directory, count, False)
                if on_chunk is not None:
                    on_chunk(count)
    _check_cancel(cancel_event)
    _atomic_status(directory, count, True)


def synthesize_to_file(text, voice, speaker, output):
    """Write the original one-shot WAV output with exclusive creation."""
    from piper.config import SynthesisConfig

    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            with wave.open(stream, 'wb') as wav:
                voice.synthesize_wav(text, wav, SynthesisConfig(speaker_id=speaker))
    except BaseException:
        output.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--speaker', type=int, default=0)
    parser.add_argument('--stream-directory', type=Path)
    args = parser.parse_args()
    text = sys.stdin.read(100001)
    try:
        validate_text(text)
        model = validate_model(args.model)
    except ValueError as error:
        parser.error(str(error))
    voice = load_voice(model)
    if args.stream_directory:
        stream_to_directory(text, voice, args.speaker, args.stream_directory)
    else:
        synthesize_to_file(text, voice, args.speaker, args.output)


if __name__ == '__main__':
    main()
