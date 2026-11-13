#!/usr/bin/env python3
"""Generate hermetic MIDI + SoundFont fixtures for MIDITests.

Outputs (committed next to this script, loaded via #filePath in tests):
  - scale.mid : a tiny format-1 MIDI file (C-major scale, 8 quarter notes
                at 120 bpm => ~4 s) used to drive AVAudioSequencer.
  - tiny.sf2  : a minimal General-MIDI-style SoundFont with ONE melodic
                instrument (a seamless-looped 440 Hz sine) -- just enough
                to prove AVAudioUnitSampler renders NON-SILENT audio.

These are deliberately tiny and SYNTHETIC. The PRODUCTION soundfont
(GeneralUser GS / FluidR3_GM) is multi-MB and is bundled by the app shell,
NOT here (PlayerCore's MIDI target declares no SPM resources). See
PlayerCore/Sources/MIDI/MIDIPlayer.swift and the task-20 license note.

Run:  python3 generate_fixtures.py
"""
import math
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))

SAMPLE_RATE = 44100
SINE_FREQ = 440.0
# 0.1 s == exactly 44 cycles of 440 Hz at 44.1 kHz, so sample[0] and
# sample[LENGTH] are both true zero crossings => a seamless whole-buffer loop.
SAMPLE_LENGTH = 4410
GUARD = 46  # SF2 spec requires >= 46 zero sample points after the last sample.


# ---------------------------------------------------------------- MIDI ------
def _vlq(value):
    """Encode an int as a MIDI variable-length quantity."""
    buf = bytearray([value & 0x7F])
    value >>= 7
    while value:
        buf.insert(0, (value & 0x7F) | 0x80)
        value >>= 7
    return bytes(buf)


def make_midi():
    division = 480  # ticks per quarter note
    events = bytearray()
    # Tempo: 120 bpm == 500000 microseconds per quarter note.
    events += _vlq(0) + bytes([0xFF, 0x51, 0x03]) + struct.pack(">I", 500000)[1:]
    # Program change: channel 0 -> program 0.
    events += _vlq(0) + bytes([0xC0, 0x00])
    for note in (60, 62, 64, 65, 67, 69, 71, 72):  # C major scale
        events += _vlq(0) + bytes([0x90, note, 0x64])       # note on, velocity 100
        events += _vlq(division) + bytes([0x80, note, 0x00])  # note off after a quarter
    events += _vlq(0) + bytes([0xFF, 0x2F, 0x00])  # end of track
    track = b"MTrk" + struct.pack(">I", len(events)) + bytes(events)
    header = b"MThd" + struct.pack(">I", 6) + struct.pack(">HHH", 1, 1, division)
    data = header + track
    with open(os.path.join(HERE, "scale.mid"), "wb") as handle:
        handle.write(data)
    return len(data)


# ----------------------------------------------------------- SoundFont ------
def _chunk(cid, data):
    out = cid + struct.pack("<I", len(data)) + data
    if len(data) & 1:
        out += b"\x00"  # RIFF chunks are word-aligned.
    return out


def _list(form, data):
    return _chunk(b"LIST", form + data)


def _name(text):
    raw = text.encode("ascii")[:20]
    return raw + b"\x00" * (20 - len(raw))


def _sample_data():
    samples = []
    for i in range(SAMPLE_LENGTH):
        value = math.sin(2.0 * math.pi * SINE_FREQ * i / SAMPLE_RATE)
        samples.append(int(max(-1.0, min(1.0, value)) * 30000))
    samples += [0] * GUARD
    return struct.pack("<%dh" % len(samples), *samples)


def make_sf2():
    # INFO
    info = _list(
        b"INFO",
        _chunk(b"ifil", struct.pack("<HH", 2, 1))
        + _chunk(b"isng", b"EMU8000\x00")
        + _chunk(b"INAM", b"MacAMP Tiny\x00"),
    )
    # sdta (16-bit mono PCM)
    sdta = _list(b"sdta", _chunk(b"smpl", _sample_data()))
    # pdta (HYDRA): one preset -> one instrument -> one sample.
    phdr = _name("Tiny") + struct.pack("<HHHIII", 0, 0, 0, 0, 0, 0)
    phdr += _name("EOP") + struct.pack("<HHHIII", 0, 0, 1, 0, 0, 0)
    pbag = struct.pack("<HH", 0, 0) + struct.pack("<HH", 1, 0)
    pmod = struct.pack("<HHhHH", 0, 0, 0, 0, 0)
    pgen = struct.pack("<HH", 41, 0) + struct.pack("<HH", 0, 0)  # 41 = instrument
    inst = _name("TinyInst") + struct.pack("<H", 0)
    inst += _name("EOI") + struct.pack("<H", 1)
    ibag = struct.pack("<HH", 0, 0) + struct.pack("<HH", 2, 0)
    imod = struct.pack("<HHhHH", 0, 0, 0, 0, 0)
    # 54 = sampleModes (1 = loop continuously); 53 = sampleID (MUST be last).
    igen = struct.pack("<HH", 54, 1) + struct.pack("<HH", 53, 0) + struct.pack("<HH", 0, 0)
    shdr = _name("TinySine") + struct.pack(
        "<IIIIIBbHH", 0, SAMPLE_LENGTH, 0, SAMPLE_LENGTH, SAMPLE_RATE, 69, 0, 0, 1
    )
    shdr += _name("EOS") + struct.pack("<IIIIIBbHH", 0, 0, 0, 0, 0, 0, 0, 0, 0)
    pdta = _list(
        b"pdta",
        _chunk(b"phdr", phdr)
        + _chunk(b"pbag", pbag)
        + _chunk(b"pmod", pmod)
        + _chunk(b"pgen", pgen)
        + _chunk(b"inst", inst)
        + _chunk(b"ibag", ibag)
        + _chunk(b"imod", imod)
        + _chunk(b"igen", igen)
        + _chunk(b"shdr", shdr),
    )
    riff = _chunk(b"RIFF", b"sfbk" + info + sdta + pdta)
    with open(os.path.join(HERE, "tiny.sf2"), "wb") as handle:
        handle.write(riff)
    return len(riff)


if __name__ == "__main__":
    midi_bytes = make_midi()
    sf2_bytes = make_sf2()
    print("scale.mid: %d bytes" % midi_bytes)
    print("tiny.sf2 : %d bytes" % sf2_bytes)
