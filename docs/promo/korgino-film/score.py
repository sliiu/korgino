"""Score for the Korgino film. 45s, 96 BPM, C major, piano over a soft pad.

Quiet on purpose: the film is a paper page and the ear has to hear the taps.
No samples and no model calls. Run: python3 score.py
"""
import array, math, random, subprocess, sys, wave
from pathlib import Path

RATE = 48000
DURATION = 45
N = RATE * DURATION
left = array.array('f', [0]) * N
right = array.array('f', [0]) * N
rng = random.Random(20261107)

def hz(note):
    return 440 * 2 ** ((note - 69) / 12)

def add(start, dur, note, amp, kind, pan):
    off = round(start * RATE)
    freq = hz(note)
    lg = math.sqrt((1 - pan) / 2)
    rg = math.sqrt((1 + pan) / 2)
    count = min(round(dur * RATE), N - off)
    for j in range(count):
        t = j / RATE
        p = 2 * math.pi * freq * t
        if kind == 'pad':
            env = min(1, t / .6) * min(1, (dur - t) / .8)
            v = (math.sin(p) + .1 * math.sin(p * 2)) * env * amp
        else:
            env = min(1, t / .006) * math.exp(-2.4 * t) * min(1, (dur - t) / .12)
            v = (math.sin(p) + .22 * math.sin(2 * p) * math.exp(-3 * t)) * env * amp
        left[off + j] += v * lg
        right[off + j] += v * rg

# Cmaj9, Am9, Fmaj9, G. One chord per shot boundary, held.
# 0 hook, 5 popup, 13 plugins, 20 voice, 28 captions, 38 end.
chords = [
    (0, 5, [48, 55, 60, 64, 67]),
    (5, 13, [45, 52, 57, 60, 64]),
    (13, 20, [41, 53, 57, 60, 65]),
    (20, 28, [43, 50, 55, 59, 62]),
    (28, 38, [48, 55, 60, 64, 67]),
    (38, 45, [48, 55, 60, 64, 72]),
]
for start, end, chord in chords:
    dur = end - start + 1.2
    for i, note in enumerate(chord):
        add(start, dur, note, .02, 'pad', (i - 2) * .22)

# A short figure at each shot change, then space. The reading stays quiet.
figures = [
    (0.4, [72, 76, 79]),
    (5.3, [76, 79, 72]),
    (13.3, [77, 72, 75]),
    (20.4, [74, 79, 71]),
    (28.3, [72, 76, 79, 84]),
    (38.4, [72, 76, 79, 84]),
]
for start, notes in figures:
    for i, note in enumerate(notes):
        add(start + i * .22, 1.6, note, .11, 'piano', .15 if i % 2 else -.15)

# One low note under the end card, nothing else.
add(38.2, 6, 36, .12, 'piano', 0)

def save(path):
    pcm = array.array('h')
    for i in range(N):
        t = i / RATE
        env = min(1, t / .04) * min(1, max(0, (DURATION - t) / 1.2))
        pcm.append(int(max(-.98, min(.98, left[i] * env)) * 32767))
        pcm.append(int(max(-.98, min(.98, right[i] * env)) * 32767))
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(pcm.tobytes())

out = Path('assets/music.wav')
save(Path('assets/music-raw.wav'))
subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', 'assets/music-raw.wav',
                '-af', 'loudnorm=I=-20:TP=-2.5:LRA=9', '-ar', str(RATE), str(out)], check=True)
print('wrote', out)
