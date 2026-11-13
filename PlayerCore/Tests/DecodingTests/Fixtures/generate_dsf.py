#!/usr/bin/env python3
"""Generate a minimal valid Sony DSF (DSD Stream File) fixture for decode tests.

ffmpeg can demux DSF but cannot *encode* it, so this script synthesises a DSD
bitstream directly. A 1st-order sigma-delta modulator encodes a pure sine; the
per-byte popcount carries the low-frequency tone, so the SFBAudioEngine DSD->PCM
decimation filter recovers it cleanly. Output is a 2-channel .dsf.

`rate_hz` selects the DSD family. SFBAudioEngine converts DSD64 (2 822 400 Hz)
ONLY, so a higher rate produces a fixture whose sole purpose is to be REFUSED:
MacAMP must reject it with a typed error rather than resample it.

Usage:
    python3 generate_dsf.py tone.dsf [freq_hz] [duration_s] [amplitude] [rate_hz]

DSF layout (all integers little-endian):
    "DSD " chunk (28B): magic, chunk size, total file size, metadata pointer
    "fmt " chunk (52B): version, format id, channel type/num, sample rate,
                        bits/sample, sample count per channel, block size, reserved
    "data" chunk:       magic, chunk size, then DSD samples organised as
                        per-channel 4096-byte blocks (ch0 block, ch1 block, ...).
Bit packing is LSB-first per the DSF spec (bit 0 = earliest sample).
"""
import math
import struct
import sys

DSD64_RATE = 2_822_400
DSD128_RATE = 5_644_800
BLOCK_BYTES_PER_CHANNEL = 4096
CHANNELS = 2


def modulate_sine(num_samples: int, freq: float, amplitude: float, rate: int) -> list[int]:
    """1st-order sigma-delta: returns a list of 0/1 bits encoding the sine."""
    bits = [0] * num_samples
    accumulator = 0.0
    step = 2.0 * math.pi * freq / rate
    for index in range(num_samples):
        target = amplitude * math.sin(step * index)
        if accumulator >= 0.0:
            bits[index] = 1
            feedback = 1.0
        else:
            bits[index] = 0
            feedback = -1.0
        accumulator += target - feedback
    return bits


def pack_lsb_first(bits: list[int]) -> bytearray:
    """Pack bits into bytes, earliest sample in the LSB (DSF convention)."""
    data = bytearray((len(bits) + 7) // 8)
    for index, bit in enumerate(bits):
        if bit:
            data[index >> 3] |= 1 << (index & 7)
    return data


def generate(path: str, freq: float, duration: float, amplitude: float, rate: int = DSD64_RATE) -> None:
    samples_per_channel = int(rate * duration)
    channel_bytes = pack_lsb_first(modulate_sine(samples_per_channel, freq, amplitude, rate))

    block_count = (len(channel_bytes) + BLOCK_BYTES_PER_CHANNEL - 1) // BLOCK_BYTES_PER_CHANNEL
    payload = bytearray()
    for block_index in range(block_count):
        start = block_index * BLOCK_BYTES_PER_CHANNEL
        chunk = channel_bytes[start:start + BLOCK_BYTES_PER_CHANNEL]
        chunk = chunk + bytes(BLOCK_BYTES_PER_CHANNEL - len(chunk))
        for _ in range(CHANNELS):
            payload += chunk

    dsd_chunk_size = 28
    fmt_chunk_size = 52
    data_chunk_size = 12 + len(payload)
    total_size = dsd_chunk_size + fmt_chunk_size + data_chunk_size

    with open(path, "wb") as out:
        out.write(b"DSD ")
        out.write(struct.pack("<QQQ", dsd_chunk_size, total_size, 0))
        out.write(b"fmt ")
        out.write(struct.pack("<Q", fmt_chunk_size))
        out.write(struct.pack("<II", 1, 0))                 # version, format id (DSD raw)
        out.write(struct.pack("<II", CHANNELS, CHANNELS))   # channel type (2=stereo), channel num
        out.write(struct.pack("<I", rate))
        out.write(struct.pack("<I", 1))                     # bits per sample
        out.write(struct.pack("<Q", samples_per_channel))
        out.write(struct.pack("<I", BLOCK_BYTES_PER_CHANNEL))
        out.write(struct.pack("<I", 0))                     # reserved
        out.write(b"data")
        out.write(struct.pack("<Q", data_chunk_size))
        out.write(payload)


if __name__ == "__main__":
    out_path = sys.argv[1] if len(sys.argv) > 1 else "tone.dsf"
    frequency = float(sys.argv[2]) if len(sys.argv) > 2 else 1000.0
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    gain = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5
    sample_rate = int(sys.argv[5]) if len(sys.argv) > 5 else DSD64_RATE
    generate(out_path, frequency, seconds, gain, sample_rate)
    family = f"DSD{64 * sample_rate // DSD64_RATE}" if sample_rate % DSD64_RATE == 0 else f"{sample_rate} Hz"
    print(f"wrote {out_path} ({frequency} Hz, {seconds}s, {family} stereo)")
