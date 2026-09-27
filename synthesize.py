#!/usr/bin/env python3
"""Offline Piper synthesis. Input is UTF-8 stdin, never a shell argument."""
import argparse
import json
import os
import re
from pathlib import Path
import sys
import wave


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--speaker', type=int, default=0)
    parser.add_argument('--stream-directory', type=Path)
    args = parser.parse_args()
    text = sys.stdin.read(100001)
    if not text.strip() or len(text) > 100000:
        parser.error('Text must contain 1–100000 characters.')
    if not args.model.is_file() or not Path(str(args.model) + '.json').is_file():
        parser.error('Local voice model is missing.')
    # German eSpeak phonemes require no network or auto-downloaded resources.
    from piper import PiperVoice
    from piper.config import PiperConfig, SynthesisConfig
    import onnxruntime as ort
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    config = PiperConfig.from_dict(json.loads(
        Path(str(args.model) + '.json').read_text(encoding='utf-8')))
    class GermanVoice(PiperVoice):
        def phonemize(self, value):
            # Piper 1.8 emits decomposed c + cedilla; this model was trained
            # with the precomposed IPA ç for the German "ich" sound.
            return [list(''.join(sentence).replace('c\u0327', 'ç'))
                    for sentence in super().phonemize(value)]

    voice = GermanVoice(ort.InferenceSession(str(args.model), sess_options=options,
                       providers=['CPUExecutionProvider']), config, use_tashkeel=False)
    if args.stream_directory:
        directory = args.stream_directory
        directory.mkdir(parents=True, exist_ok=True)
        count = 0

        def progress(done):
            temporary = directory / 'status.next'
            temporary.write_text(json.dumps({'count': count, 'done': done}), encoding='utf-8')
            os.replace(temporary, directory / 'status.json')

        progress(False)
        # Small first phrase starts playback quickly; later phrases fill the buffer.
        for sentence in re.split(r'(?<=[.!?])\s+|\n+', text):
            remaining = sentence.strip()
            while remaining:
                limit = 55 if count == 0 else 280
                if len(remaining) > limit:
                    cut = remaining.rfind(' ', 0, limit + 1)
                    cut = cut if cut > 0 else limit
                    part, remaining = remaining[:cut], remaining[cut:].lstrip()
                else:
                    part, remaining = remaining, ''
                for chunk in voice.synthesize(part, SynthesisConfig(speaker_id=args.speaker)):
                    temporary = directory / f'chunk-{count:05d}.next'
                    with wave.open(str(temporary), 'wb') as wav:
                        wav.setnchannels(chunk.sample_channels)
                        wav.setsampwidth(chunk.sample_width)
                        wav.setframerate(chunk.sample_rate)
                        wav.writeframes(chunk.audio_int16_bytes)
                    os.chmod(temporary, 0o600)
                    (directory / f'chunk-{count:05d}.json').write_text(
                        json.dumps({'text': part}, ensure_ascii=False), encoding='utf-8')
                    os.chmod(directory / f'chunk-{count:05d}.json', 0o600)
                    os.replace(temporary, directory / f'chunk-{count:05d}.wav')
                    count += 1
                    progress(False)
        progress(True)
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as output:
            with wave.open(output, 'wb') as wav:
                voice.synthesize_wav(text, wav, SynthesisConfig(speaker_id=args.speaker))
    except BaseException:
        args.output.unlink(missing_ok=True)
        raise


if __name__ == '__main__':
    main()
