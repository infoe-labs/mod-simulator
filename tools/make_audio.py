#!/usr/bin/env python3
"""Synthesise every sound effect and the music loop as 16-bit WAV files.

No audio files are checked in or downloaded; they are generated from
parameters, so they can be regenerated or tweaked at any time:

    python3 tools/make_audio.py

Writes 22050 Hz mono PCM into game/assets/audio/.
"""
from __future__ import annotations
import array
import math
import os
import random
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "game", "assets", "audio"))
RATE = 22050
AMPLITUDE = 0.55


def write_wav(name: str, samples: list[float]) -> None:
    peak = max((abs(s) for s in samples), default=1.0)
    scale = AMPLITUDE / peak if peak > 0 else 1.0
    frames = array.array("h", (int(max(-1.0, min(1.0, s * scale)) * 32767) for s in samples))
    path = os.path.join(OUT, name)
    with open(path, "wb") as fh:
        data = frames.tobytes()
        fh.write(b"RIFF")
        fh.write(struct.pack("<I", 36 + len(data)))
        fh.write(b"WAVEfmt ")
        fh.write(struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16))
        fh.write(b"data")
        fh.write(struct.pack("<I", len(data)))
        fh.write(data)
    print(f"  assets/audio/{name}  {len(samples) / RATE:.2f}s  {len(data) / 1024:.0f} KB")


def env(i: int, n: int, attack: float = 0.01, release: float = 0.15) -> float:
    t = i / max(1, n - 1)
    a = min(1.0, t / attack) if attack > 0 else 1.0
    r = min(1.0, (1.0 - t) / release) if release > 0 else 1.0
    return a * r


def tone(freq: float, secs: float, shape: str = "sine", sweep: float | None = None,
         vibrato: float = 0.0, harmonics: float = 0.0) -> list[float]:
    n = int(RATE * secs)
    out = []
    for i in range(n):
        t = i / RATE
        f = freq if sweep is None else freq + (sweep - freq) * (i / max(1, n - 1))
        if vibrato:
            f *= 1.0 + vibrato * math.sin(2 * math.pi * 5.5 * t)
        ph = 2 * math.pi * f * t
        if shape == "square":
            v = 1.0 if math.sin(ph) >= 0 else -1.0
            v = 0.65 * v + 0.35 * math.sin(ph)
        elif shape == "tri":
            v = 2.0 / math.pi * math.asin(math.sin(ph))
        else:
            v = math.sin(ph)
        if harmonics:
            v += harmonics * 0.4 * math.sin(2 * ph) + harmonics * 0.15 * math.sin(3 * ph)
        out.append(v * env(i, n))
    return out


def noise(secs: float, lp: float = 0.25, seed: int = 7) -> list[float]:
    rnd = random.Random(seed)
    n = int(RATE * secs)
    out = []
    acc = 0.0
    for i in range(n):
        acc += lp * (rnd.uniform(-1.0, 1.0) - acc)
        out.append(acc * env(i, n, 0.02, 0.4))
    return out


def mix(*tracks: list[float]) -> list[float]:
    n = max(len(t) for t in tracks)
    return [sum(t[i] if i < len(t) else 0.0 for t in tracks) for i in range(n)]


def notes(seq: list[tuple[float, float, float]], shape: str = "tri") -> list[float]:
    """seq of (start, dur, freq)."""
    total = max(s + d for s, d, _ in seq)
    out = [0.0] * int(RATE * total)
    for start, dur, f in seq:
        seg = tone(f, dur, shape)
        off = int(RATE * start)
        for i, v in enumerate(seg):
            if off + i < len(out):
                out[off + i] += v
    return out


def music_loop(secs: float = 12.0) -> list[float]:
    """Cozy 12-second pad. Every partial completes a whole number of cycles in
    the loop, so it seams without a click; the low-level 'rain' bed is noise
    far enough below the tonal material that its seam is inaudible."""
    grid = 1.0 / secs
    def snap(f: float) -> float:
        return round(f / grid) * grid

    n = int(RATE * secs)
    out = [0.0] * n
    # A minor 9 pad, soft triangle stack, gently detuned.
    for base in (110.0, 164.81, 220.0, 261.63, 329.63):
        f = snap(base)
        for det, amp in ((0.0, 1.0), (0.6, 0.45), (-0.5, 0.3)):
            fq = snap(f + det)
            for i in range(n):
                t = i / RATE
                lfo = 0.55 + 0.45 * math.sin(2 * math.pi * 2.0 * t + base)
                out[i] += amp * lfo * math.sin(2 * math.pi * fq * t) / 3.0
    # soft plucked motif on top, pentatonic, sparse
    motif = [(0.0, 1.2), (1.5, 0.9), (3.0, 1.2), (4.5, 0.75), (6.0, 1.5),
             (7.5, 0.9), (9.0, 1.2), (10.5, 1.2)]
    scale = [440.0, 523.25, 587.33, 659.25, 783.99]
    rnd = random.Random(11)
    for k, (start, dur) in enumerate(motif):
        f = snap(scale[rnd.randrange(len(scale))])
        seg = tone(f, dur, "sine", harmonics=0.4)
        peak = max(abs(v) for v in seg) or 1.0
        off = int(RATE * start)
        for i, v in enumerate(seg):
            if off + i < n:
                out[off + i] += 0.30 * v / peak
    # rain / room bed
    bed = noise(secs, lp=0.05, seed=3)
    peak = max(abs(v) for v in bed) or 1.0
    for i in range(n):
        out[i] += 0.10 * bed[i] / peak
    return out


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    print("audio:")
    write_wav("click.wav", mix(tone(880, 0.05, "sine", sweep=1180), noise(0.03, 0.5, 2)))
    write_wav("tap.wav", tone(520, 0.045, "sine", sweep=470))
    write_wav("back.wav", tone(420, 0.07, "sine", sweep=280))
    write_wav("good.wav", notes([(0.0, 0.09, 784.0), (0.07, 0.13, 1046.5)]))
    write_wav("warn.wav", notes([(0.0, 0.09, 440.0), (0.14, 0.10, 440.0)], "square"))
    write_wav("error.wav", mix(tone(180, 0.26, "square", sweep=120), noise(0.12, 0.2, 5)))
    write_wav("allow.wav", notes([(0.0, 0.10, 659.25), (0.08, 0.16, 987.77)]))
    write_wav("delete.wav", mix(tone(300, 0.14, "tri", sweep=180), noise(0.13, 0.3, 9)))
    write_wav("ban.wav", mix(tone(420, 0.3, "square", sweep=110), noise(0.22, 0.12, 4)))
    write_wav("combo.wav", notes([(0.0, 0.08, 659.25), (0.07, 0.08, 830.61),
                                  (0.14, 0.16, 987.77), (0.21, 0.22, 1318.5)]))
    write_wav("phase.wav", notes([(0.0, 0.5, 523.25), (0.0, 0.5, 659.25), (0.0, 0.5, 783.99)], "sine"))
    write_wav("win.wav", notes([(0.0, 0.16, 523.25), (0.14, 0.16, 659.25), (0.28, 0.16, 783.99),
                                (0.42, 0.5, 1046.5), (0.42, 0.5, 1318.5)]))
    write_wav("lose.wav", notes([(0.0, 0.34, 440.0), (0.3, 0.34, 349.23), (0.6, 0.7, 293.66)], "tri"))
    write_wav("loop_cozy.wav", music_loop())


if __name__ == "__main__":
    main()
