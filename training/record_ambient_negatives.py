#!/usr/bin/env python3
"""Record ambient noise clips from the microphone for wake word negative training.

Automatically records 2-second clips in a loop for a specified duration (default
30 minutes), saving each clip into real_clips_negative/ambient_recorded/.

Runs on the dev machine — uses arecord (ALSA).

Usage:
    python3 record_ambient_negatives.py                  # 30 minutes
    python3 record_ambient_negatives.py --minutes 60     # 1 hour
    python3 record_ambient_negatives.py --minutes 10 --pause 1.0
"""

import argparse
import math
import os
import struct
import subprocess
import sys
import time
import uuid
import wave

SAMPLE_RATE = 16000
CLIP_DURATION = 2.0  # seconds — must be 2s to produce correct 16-frame embeddings
OUTPUT_SUBDIR = "ambient_recorded"


def get_wav_rms(filepath):
    """Calculate RMS of a WAV file to detect silence."""
    with wave.open(filepath, "rb") as wf:
        data = wf.readframes(wf.getnframes())
    count = len(data) // 2
    if count == 0:
        return 0
    shorts = struct.unpack(f"{count}h", data)
    return math.sqrt(sum(s * s for s in shorts) / count)


def record_clip(filepath, device=None):
    """Record a single 2-second clip using arecord."""
    cmd = [
        "arecord",
        "-f", "S16_LE",
        "-r", str(SAMPLE_RATE),
        "-c", "1",
        "-t", "wav",
        "-d", str(int(CLIP_DURATION)),
        "-q",
    ]
    if device:
        cmd.extend(["-D", device])
    cmd.append(filepath)
    try:
        subprocess.run(cmd, check=True, timeout=CLIP_DURATION + 5)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"  Recording failed: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Record ambient noise clips for wake word negative training"
    )
    parser.add_argument("--minutes", type=float, default=30.0,
                        help="How long to record in minutes (default: 30)")
    parser.add_argument("--pause", type=float, default=0.5,
                        help="Pause between clips in seconds (default: 0.5)")
    parser.add_argument("--min-rms", type=float, default=50,
                        help="Minimum RMS to keep a clip (default: 50, very low "
                             "to keep quiet ambient sounds)")
    parser.add_argument("--device", "-D", default=None,
                        help="ALSA device (e.g. hw:2,0 for Jabra)")
    parser.add_argument("--output-dir", default=None,
                        help="Output directory (default: real_clips_negative/ambient_recorded/)")
    args = parser.parse_args()

    if args.output_dir is None:
        args.output_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "real_clips_negative", OUTPUT_SUBDIR
        )

    os.makedirs(args.output_dir, exist_ok=True)
    existing = len([f for f in os.listdir(args.output_dir) if f.endswith(".wav")])

    total_seconds = args.minutes * 60
    approx_clips = int(total_seconds / (CLIP_DURATION + args.pause))

    print(f"Recording ambient noise clips")
    print(f"  Duration:  {args.minutes} minutes ({total_seconds:.0f}s)")
    print(f"  Clip len:  {CLIP_DURATION}s each, ~{approx_clips} clips expected")
    print(f"  Pause:     {args.pause}s between clips")
    print(f"  Min RMS:   {args.min_rms}")
    print(f"  Output:    {args.output_dir}")
    print(f"  Existing:  {existing} clips already in directory")
    print()
    print("Press Ctrl+C to stop early.\n")

    recorded = 0
    discarded = 0
    start_time = time.time()

    try:
        while (time.time() - start_time) < total_seconds:
            elapsed = time.time() - start_time
            remaining = total_seconds - elapsed
            mins_left = remaining / 60

            filename = f"ambient_{uuid.uuid4().hex[:12]}.wav"
            filepath = os.path.join(args.output_dir, filename)

            print(f"  [{mins_left:.1f}m left] Recording clip {recorded + 1}...",
                  end="", flush=True)

            if not record_clip(filepath, device=args.device):
                discarded += 1
                print(" FAILED")
                continue

            rms = get_wav_rms(filepath)
            if rms < args.min_rms:
                os.remove(filepath)
                discarded += 1
                print(f" too quiet (rms={rms:.0f}), discarded")
            else:
                recorded += 1
                print(f" saved (rms={rms:.0f})")

            if args.pause > 0:
                time.sleep(args.pause)

    except KeyboardInterrupt:
        elapsed = time.time() - start_time
        print(f"\n\nStopped after {elapsed / 60:.1f} minutes.")

    total = existing + recorded
    print(f"\nDone! Recorded {recorded} new clips, discarded {discarded}")
    print(f"Total clips in output dir: {total}")
    print(f"\nNext step: rebuild ambient features with:")
    print(f"  python build_ambient_features.py")


if __name__ == "__main__":
    main()
