#!/usr/bin/env python3
import argparse
import base64
import json
import sys
import time
import uuid
import wave

import numpy as np
import sherpa_onnx


TARGET_SAMPLE_RATE = 16000
SOURCE = "local_parakeet_asr"


def eprint(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def read_wav(path: str) -> tuple[int, np.ndarray]:
    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        sample_rate = wav.getframerate()
        sample_width = wav.getsampwidth()
        frames = wav.readframes(wav.getnframes())

    if sample_width != 2:
        raise ValueError(f"Expected 16-bit PCM WAV, got sample width {sample_width}")
    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return sample_rate, samples


def resample_linear(samples: np.ndarray, source_rate: int, target_rate: int = TARGET_SAMPLE_RATE) -> np.ndarray:
    if source_rate == target_rate or samples.size == 0:
        return samples.astype(np.float32, copy=False)
    duration = samples.size / float(source_rate)
    target_count = max(1, int(round(duration * target_rate)))
    source_x = np.linspace(0.0, duration, num=samples.size, endpoint=False)
    target_x = np.linspace(0.0, duration, num=target_count, endpoint=False)
    return np.interp(target_x, source_x, samples).astype(np.float32)


def create_recognizer(model_dir: str, num_threads: int) -> sherpa_onnx.OfflineRecognizer:
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=f"{model_dir}/encoder.int8.onnx",
        decoder=f"{model_dir}/decoder.int8.onnx",
        joiner=f"{model_dir}/joiner.int8.onnx",
        tokens=f"{model_dir}/tokens.txt",
        num_threads=num_threads,
        sample_rate=TARGET_SAMPLE_RATE,
        feature_dim=80,
        provider="cpu",
        model_type="nemo_transducer",
    )


def decode_samples(recognizer: sherpa_onnx.OfflineRecognizer, sample_rate: int, samples: np.ndarray) -> str:
    samples_16k = resample_linear(samples, sample_rate)
    stream = recognizer.create_stream()
    stream.accept_waveform(TARGET_SAMPLE_RATE, samples_16k)
    recognizer.decode_stream(stream)
    return stream.result.text.strip()


def emit_event(text: str, start_time: float, end_time: float, segment_id: str | None = None) -> None:
    if not text:
        return
    print(
        json.dumps(
            {
                "segmentId": segment_id or str(uuid.uuid4()),
                "text": text,
                "isFinal": True,
                "startTime": start_time,
                "endTime": end_time,
                "confidence": None,
                "source": SOURCE,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )


class UtteranceDecoder:
    def __init__(
        self,
        recognizer: sherpa_onnx.OfflineRecognizer,
        silence_threshold: float,
        trailing_silence_seconds: float,
        min_utterance_seconds: float,
        max_utterance_seconds: float,
    ) -> None:
        self.recognizer = recognizer
        self.silence_threshold = silence_threshold
        self.trailing_silence_seconds = trailing_silence_seconds
        self.min_utterance_seconds = min_utterance_seconds
        self.max_utterance_seconds = max_utterance_seconds
        self.audio_clock = 0.0
        self.segment_start = 0.0
        self.silence_seconds = 0.0
        self.active_chunks: list[np.ndarray] = []

    def accept_audio(self, sample_rate: int, samples: np.ndarray) -> None:
        if samples.size == 0:
            return
        samples_16k = resample_linear(samples, sample_rate)
        duration = samples_16k.size / float(TARGET_SAMPLE_RATE)
        rms = float(np.sqrt(np.mean(np.square(samples_16k)))) if samples_16k.size else 0.0
        speech_like = rms >= self.silence_threshold

        if speech_like and not self.active_chunks:
            self.segment_start = self.audio_clock
            self.silence_seconds = 0.0

        if self.active_chunks or speech_like:
            self.active_chunks.append(samples_16k)
            if speech_like:
                self.silence_seconds = 0.0
            else:
                self.silence_seconds += duration

        self.audio_clock += duration
        active_duration = sum(chunk.size for chunk in self.active_chunks) / float(TARGET_SAMPLE_RATE)
        if self.active_chunks and (
            (self.silence_seconds >= self.trailing_silence_seconds and active_duration >= self.min_utterance_seconds)
            or active_duration >= self.max_utterance_seconds
        ):
            self.flush()

    def flush(self) -> None:
        if not self.active_chunks:
            return
        samples = np.concatenate(self.active_chunks).astype(np.float32, copy=False)
        duration = samples.size / float(TARGET_SAMPLE_RATE)
        if duration >= self.min_utterance_seconds:
            start = time.perf_counter()
            text = decode_samples(self.recognizer, TARGET_SAMPLE_RATE, samples)
            eprint(f"decoded utterance duration={duration:.2f}s latency={time.perf_counter() - start:.2f}s text_length={len(text)}")
            emit_event(text, self.segment_start, self.segment_start + duration)
        self.active_chunks = []
        self.silence_seconds = 0.0


def samples_from_audio_event(event: dict) -> tuple[int, np.ndarray]:
    if event.get("encoding") != "float32le":
        raise ValueError(f"Unsupported audio encoding: {event.get('encoding')}")
    sample_rate = int(event["sampleRate"])
    raw = base64.b64decode(event["audio"])
    samples = np.frombuffer(raw, dtype="<f4").astype(np.float32, copy=False)
    channels = int(event.get("channels", 1))
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return sample_rate, samples


def run_jsonl_loop(args: argparse.Namespace) -> int:
    recognizer = create_recognizer(args.model_dir, args.num_threads)
    decoder = UtteranceDecoder(
        recognizer=recognizer,
        silence_threshold=args.silence_threshold,
        trailing_silence_seconds=args.trailing_silence_seconds,
        min_utterance_seconds=args.min_utterance_seconds,
        max_utterance_seconds=args.max_utterance_seconds,
    )
    eprint(f"parakeet sidecar ready session={args.session_id} capture_mode={args.capture_mode}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            event_type = event.get("type")
            if event_type == "audio":
                sample_rate, samples = samples_from_audio_event(event)
                decoder.accept_audio(sample_rate, samples)
            elif event_type == "flush":
                decoder.flush()
            elif event_type == "stop":
                decoder.flush()
                return 0
            else:
                raise ValueError(f"Unsupported event type: {event_type}")
        except Exception as exc:
            print(json.dumps({"type": "error", "message": str(exc)}), flush=True)
            eprint(f"error: {exc}")
    decoder.flush()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Interview Copilot Parakeet ASR sidecar")
    parser.add_argument("--health", action="store_true")
    parser.add_argument("--model-dir")
    parser.add_argument("--session-id", default="sidecar")
    parser.add_argument("--capture-mode", default="systemAudioOnly")
    parser.add_argument("--jsonl", action="store_true")
    parser.add_argument("--wav")
    parser.add_argument("--num-threads", type=int, default=2)
    parser.add_argument("--silence-threshold", type=float, default=0.0035)
    parser.add_argument("--trailing-silence-seconds", type=float, default=0.85)
    parser.add_argument("--min-utterance-seconds", type=float, default=0.35)
    parser.add_argument("--max-utterance-seconds", type=float, default=14.0)
    args = parser.parse_args()

    try:
        if args.health:
            print(json.dumps({"status": "ok", "runtime": "sherpa_onnx", "source": SOURCE}), flush=True)
            return 0
        if not args.model_dir:
            raise ValueError("--model-dir is required unless --health is used")
        if args.wav:
            start = time.perf_counter()
            recognizer = create_recognizer(args.model_dir, args.num_threads)
            sample_rate, samples = read_wav(args.wav)
            text = decode_samples(recognizer, sample_rate, samples)
            emit_event(text, 0.0, samples.size / float(sample_rate), segment_id="wav-test")
            eprint(f"wav decode latency={time.perf_counter() - start:.2f}s")
            return 0
        return run_jsonl_loop(args)
    except Exception as exc:
        print(json.dumps({"type": "error", "message": str(exc)}), flush=True)
        eprint(f"fatal: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
