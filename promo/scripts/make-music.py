#!/usr/bin/env python3
"""The film's soundtrack, synthesized from scratch (numpy + scipy, no samples), on the beat grid
of src/timeline.json: 120 BPM in F major, Fmaj7 – Am7 – Dm9 – B♭maj7 every four bars.

  intro    (bars 0–4)   pad opening its filter, plucked arpeggio, the icon's pops, ⌘K
  features (4–16)       kick, clap, hats, sidechained bass, arpeggio; a whoosh on every cut
  fakeEnd  (16–18)      everything drops out to the pad; a riser; one beat of silence
  big      (18–26)      the drop: impact, open hats, octave bass, chord stabs
  outro    (26–32)      drums thin out, a final chord on bar 30 rings out

Writes public/audio/music.wav (48 kHz stereo, -1 dBFS peak).
"""
import json
import os

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, sosfilt

ROOT = os.path.join(os.path.dirname(__file__), "..")
T = json.load(open(os.path.join(ROOT, "src", "timeline.json")))
SR = 48000
BEAT = 60 / T["bpm"]
BAR = BEAT * T["beatsPerBar"]
LENGTH = T["bars"] * BAR + 2.0
N = int(LENGTH * SR)
rng = np.random.default_rng(7)

left = np.zeros(N)
right = np.zeros(N)
reverb_send = np.zeros(N)


def at(bar):
    return int(round(bar * BAR * SR))


def add(signal, start, gain=1.0, pan=0.0, send=0.0):
    """Mix a mono signal in at sample `start`; pan −1 … 1; `send` feeds the reverb."""
    end = min(N, start + len(signal))
    if end <= start:
        return
    s = signal[: end - start] * gain
    left[start:end] += s * np.sqrt((1 - pan) / 2) * 1.414
    right[start:end] += s * np.sqrt((1 + pan) / 2) * 1.414
    reverb_send[start:end] += s * send


def env(n, attack, release, sustain_len=None):
    """Attack / hold / exponential release envelope of n samples."""
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    hold = sustain_len if sustain_len is not None else 0
    r = np.where(t < attack + hold, 1.0, np.exp(-(t - attack - hold) / max(release, 1e-4)))
    return a * r


def lowpass(x, hz, order=2):
    return sosfilt(butter(order, min(hz, SR / 2 - 100), "low", fs=SR, output="sos"), x)


def highpass(x, hz, order=2):
    return sosfilt(butter(order, hz, "high", fs=SR, output="sos"), x)


def bandpass(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, min(hi, SR / 2 - 100)], "band", fs=SR, output="sos"), x)


def hz(note):
    """MIDI note number → frequency."""
    return 440.0 * 2 ** ((note - 69) / 12)


def saw(freq, n, detune=0.0):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for d in (-detune, 0.0, detune) if detune else (0.0,):
        phase = (t * freq * (1 + d) + rng.random()) % 1.0
        out += 2 * phase - 1
    return out / (3 if detune else 1)


def sine(freq, n):
    return np.sin(2 * np.pi * freq * np.arange(n) / SR)


# F major: Fmaj7, Am7, Dm9, B♭maj7 (MIDI notes), and bass roots.
CHORDS = [[53, 57, 60, 64], [57, 60, 64, 67], [50, 53, 57, 60, 64], [58, 62, 65, 69]]
ROOTS = [41, 45, 38, 46]


def section(bar):
    for name, (a, b) in T["sections"].items():
        if a <= bar < b:
            return name
    return "outro"


# --- Instruments ------------------------------------------------------------

def kick():
    n = int(0.45 * SR)
    t = np.arange(n) / SR
    f = 45 + 110 * np.exp(-t / 0.03)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.16)
    click = highpass(rng.standard_normal(n), 2000) * np.exp(-t / 0.004) * 0.3
    return np.tanh((body + click) * 1.6)


def clap():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    noise = bandpass(rng.standard_normal(n), 900, 3500)
    e = np.zeros(n)
    for k, off in enumerate((0.0, 0.011, 0.023)):
        e += np.where(t >= off, np.exp(-(t - off) / (0.012 if k < 2 else 0.11)), 0)
    return noise * e * 0.9


def hat(open_=False):
    n = int((0.3 if open_ else 0.06) * SR)
    t = np.arange(n) / SR
    return highpass(rng.standard_normal(n), 7500, 4) * np.exp(-t / (0.09 if open_ else 0.015))


def pluck(note, length=0.28):
    n = int(length * SR)
    t = np.arange(n) / SR
    tone = saw(hz(note), n, 0.003) * 0.6 + np.sign(sine(hz(note), n)) * 0.25
    cutoff_env = 400 + 5000 * np.exp(-t / 0.05)
    # piecewise filter: approximate a decaying cutoff with two passes
    bright = lowpass(tone, 4500) * np.exp(-t / 0.05)
    dark = lowpass(tone, 900) * (1 - np.exp(-t / 0.05))
    return (bright + dark) * np.exp(-t / 0.12) * (cutoff_env > 0)


def pad(chord, length, cutoff):
    n = int(length * SR)
    out = np.zeros(n)
    for note in chord:
        out += saw(hz(note), n, 0.006)
        out += saw(hz(note + 12), n, 0.004) * 0.35
    out = lowpass(out / len(chord), cutoff, 2)
    return out * env(n, 0.35, 0.6, length - 0.95)


def stab(chord):
    n = int(0.35 * SR)
    out = np.zeros(n)
    for note in chord:
        out += saw(hz(note + 12), n, 0.01)
    return lowpass(out / len(chord), 3800) * env(n, 0.003, 0.09)


def bass_note(note, length):
    n = int(length * SR)
    tone = saw(hz(note), n) * 0.5 + sine(hz(note), n)
    return lowpass(tone, 420, 3) * env(n, 0.004, 0.06, length * 0.55)


def whoosh(length=0.55):
    n = int(length * SR)
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    # sweep the band upward by blending three bands over time
    lo = bandpass(noise, 300, 1200)
    mid = bandpass(noise, 1200, 4000)
    hi = bandpass(noise, 4000, 12000)
    p = t / length
    sweep = lo * (1 - p) ** 2 + mid * 2 * p * (1 - p) + hi * p ** 2
    return sweep * np.sin(np.pi * p) ** 1.5 * 0.9


def riser(length):
    n = int(length * SR)
    t = np.arange(n) / SR
    p = t / length
    noise = highpass(rng.standard_normal(n), 800) * p ** 2
    f = 200 * 2 ** (p * 3)
    tone = np.sin(2 * np.pi * np.cumsum(f) / SR) * p ** 3 * 0.3
    return (noise * 0.5 + tone) * (1 - np.exp(-(length - t) / 0.01))


def impact():
    n = int(2.0 * SR)
    t = np.arange(n) / SR
    f = 38 + 60 * np.exp(-t / 0.05)
    boom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.6)
    crash = highpass(rng.standard_normal(n), 3000) * np.exp(-t / 0.5) * 0.25
    return np.tanh(boom * 1.4) + crash


def pop():
    n = int(0.12 * SR)
    t = np.arange(n) / SR
    f = 900 * np.exp(-t / 0.03) + 300
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.03)


def key_click():
    n = int(0.08 * SR)
    t = np.arange(n) / SR
    return bandpass(rng.standard_normal(n), 2000, 7000) * np.exp(-t / 0.006) + sine(180, n) * np.exp(-t / 0.01) * 0.4


def ding():
    n = int(1.2 * SR)
    t = np.arange(n) / SR
    out = sum(sine(hz(n_), n) * g for n_, g in ((84, 1.0), (91, 0.4), (96, 0.25)))
    return out * np.exp(-t / 0.35) * 0.5


# --- Arrangement --------------------------------------------------------------

K, C, H, HO = kick(), clap(), hat(), hat(True)
kick_times = []
bars = T["bars"]
for bar in range(bars):
    sec = section(bar)
    chord = CHORDS[bar % 4]
    root = ROOTS[bar % 4]
    start = at(bar)

    # pad: through everything; the filter opens over the intro
    if sec == "intro":
        cutoff = 500 + 2500 * (bar / 4)
    elif sec == "fakeEnd":
        cutoff = 1800
    else:
        cutoff = 3200
    if bar < 30:
        pad_gain = 0.16 if sec in ("intro", "fakeEnd") else 0.11
        add(pad(chord, BAR + 0.3, cutoff), start, pad_gain, 0.0, 0.5)

    drums = sec in ("features", "big") or (sec == "outro" and bar < 29) or (sec == "intro" and bar == 3)
    full = sec == "big"
    for beat in range(4):
        b = bar + beat / 4
        if drums and not (sec == "intro"):
            kick_times.append((at(b), 0.9 if full else 0.7))
            if beat in (1, 3):
                add(C, at(b), 0.45 if full else 0.3, 0.1, 0.25)
        for eighth in range(2):
            e = b + eighth / 8
            if drums and sec != "intro":
                if full and eighth == 1:
                    add(HO, at(e), 0.16, 0.3)
                else:
                    add(H, at(e), (0.13 if eighth else 0.07) * (1 if full else 0.7), 0.3)
            # bass on off-beat eighths (and 16ths in the drop)
            if drums and sec != "intro" and bar < 29:
                add(bass_note(root + (12 if full and eighth else 0), BEAT / 2 * 0.9), at(e + 1 / 16), 0.32 if full else 0.22)

    # intro bar 3: a four-on-the-floor tease on the last two beats
    if sec == "intro" and bar == 3:
        for beat in (2, 3):
            kick_times.append((at(bar + beat / 4), 0.6))

    # plucked arpeggio: 16ths up and down the chord, a dotted echo
    if bar < 29 and sec != "fakeEnd":
        pattern = chord + [chord[-1] + 12] + chord[::-1][1:]
        for i in range(16):
            note = pattern[i % len(pattern)] + 12
            g = (0.10 if full else 0.075) if sec != "intro" else 0.06 + 0.02 * bar
            add(pluck(note), at(bar + i / 16), g, 0.35 if i % 2 else -0.35, 0.35)
            add(pluck(note), at(bar + i / 16 + 3 / 32), g * 0.35, -0.5 if i % 2 else 0.5, 0.2)

    # chord stabs on the off-beats in the drop, and a sub under every bar
    if full:
        add(sine(hz(root - 12), int(BAR * SR)) * env(int(BAR * SR), 0.01, 0.3, BAR - 0.4), start, 0.18)
        for beat in range(4):
            add(stab(chord), at(bar + beat / 4 + 1 / 8), 0.12, -0.2 if beat % 2 else 0.2, 0.4)

# final chord on bar 30 rings out
final = CHORDS[0] + [65, 72]
add(pad(final, 6.0, 4000), at(30), 0.22, 0, 0.8)
add(stab(final), at(30), 0.25, 0, 0.6)

# sidechain: duck everything but the kick after each kick
duck = np.ones(N)
dk = 1 - 0.55 * np.exp(-np.arange(int(0.25 * SR)) / SR / 0.06)
for k, _ in kick_times:
    e = min(N, k + len(dk))
    duck[k:e] = np.minimum(duck[k:e], dk[: e - k])
left *= duck
right *= duck
reverb_send *= duck
# the kicks themselves go in after the ducking
for k, g in kick_times:
    add(K, k, g)

# --- Sound effects --------------------------------------------------------------
for s in T["sfx"]:
    t0 = at(s["bar"])
    kind = s["type"]
    if kind == "whoosh":
        add(whoosh(), t0 - int(0.3 * SR), 0.35, 0.0, 0.3)
    elif kind == "riser":
        add(riser(s["length"] * BAR), t0, 0.45, 0.0, 0.3)
    elif kind == "impact":
        add(impact(), t0, 0.7, 0.0, 0.5)
    elif kind == "pop":
        add(pop(), t0, 0.35, rng.uniform(-0.4, 0.4), 0.3)
    elif kind == "key":
        add(key_click(), t0, 0.6, 0.0, 0.1)
    elif kind == "ding":
        add(ding(), t0, 0.6, 0.2, 0.5)

# --- Reverb, master -----------------------------------------------------------------
ir_n = int(1.8 * SR)
ir_t = np.arange(ir_n) / SR
ir_l = rng.standard_normal(ir_n) * np.exp(-ir_t / 0.45)
ir_r = rng.standard_normal(ir_n) * np.exp(-ir_t / 0.45)
ir_l, ir_r = lowpass(ir_l, 6000), lowpass(ir_r, 6000)
wet_l = fftconvolve(reverb_send, ir_l)[:N] * 0.02
wet_r = fftconvolve(reverb_send, ir_r)[:N] * 0.02
left += wet_l
right += wet_r

# one beat of silence before the drop (the fake ending's catch), reverb tails included
gap0, gap1 = at(17.75), at(18) - int(0.01 * SR)
ramp = np.linspace(1, 0, int(0.05 * SR))
for ch in (left, right):
    ch[gap0 : gap0 + len(ramp)] *= ramp
    ch[gap0 + len(ramp) : gap1] = 0

mix = np.stack([left, right], axis=1)
mix = highpass(mix.T, 25).T
peak = np.max(np.abs(mix))
mix = np.tanh(mix / peak * 1.4) / np.tanh(1.4)
fade = np.ones(N)
fade[-int(1.5 * SR):] = np.linspace(1, 0, int(1.5 * SR))
mix *= fade[:, None]
mix *= 10 ** (-1 / 20) / np.max(np.abs(mix))
os.makedirs(os.path.join(ROOT, "public", "audio"), exist_ok=True)
out = os.path.join(ROOT, "public", "audio", "music.wav")
wavfile.write(out, SR, (mix * 32767).astype(np.int16))
print(f"{out}: {LENGTH:.1f} s, {T['bpm']} BPM")
