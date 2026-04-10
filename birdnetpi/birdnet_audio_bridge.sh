#!/bin/bash
# Drain any UDP packets queued before we start, then run the ffmpeg→aplay pipeline
# with a large intermediate buffer to absorb ffmpeg stalls.

PORT=5000
SDP=/opt/birdnet-audio-bridge/stream.sdp

# Drain stale packets from the UDP port (avoids initial RTP buffer overflow)
python3 -c "
import socket, select
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('', $PORT))
s.setblocking(False)
count = 0
while select.select([s],[],[],0.1)[0]:
    s.recv(65536)
    count += 1
s.close()
if count: print(f'Drained {count} stale UDP packets')
"

# Run pipeline: ffmpeg (RTP demux + resample + filters) → ALSA loopback
exec /usr/bin/ffmpeg -loglevel warning \
  -analyzeduration 0 -probesize 32 \
  -protocol_whitelist file,udp,rtp -max_delay 5000000 \
  -i "$SDP" \
  -af "aresample=48000:async=1000:first_pts=0,volume=1,highpass=f=100,lowpass=f=11500,afftdn=nf=-25" \
  -ac 2 -f alsa plughw:Loopback,0
