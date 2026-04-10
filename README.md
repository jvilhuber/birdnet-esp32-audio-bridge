# ESP32 Microphone → BirdNET-Pi Audio Bridge

Streams audio from a Waveshare ESP32-S3 Zero with an ICS-43434 I2S microphone to a headless Raspberry Pi running
BirdNET-Pi, via RTP over UDP on the local network.

---

## Architecture

```
ICS-43434 mic
     │ I2S (32-bit slots, left channel, 24kHz effective)
ESP32-S3 Zero
     │ RTP/UDP mono L16 PCM (port 5000)
     ▼
Raspberry Pi (BirdNET-Pi)
  ffmpeg (SDP → RTP demux → 24kHz→48kHz upsample) → ALSA Loopback → BirdNET-Pi
```

**Audio format sent over RTP:** L16 (16-bit signed PCM, big-endian, mono, 24 kHz)
per RFC 3551, with standard 12-byte RTP headers (sequence numbers, timestamps, SSRC).

The ICS-43434 outputs 24-bit data in the left slot of a standard stereo I2S frame
(LR pin tied low). ESPHome's `on_data` callback delivers stereo interleaved 16-bit
samples. The ESP32 extracts the left (mono) channel, applies configurable digital
gain, byte-swaps to big-endian L16, and sends RTP packets of 720 samples (30ms)
each. ffmpeg on the Pi reads the RTP stream via a static SDP file and upsamples to
48 kHz for BirdNET.

RTP sequence numbers let ffmpeg detect packet loss and insert silence instead of
glitching. RTP timestamps enable jitter buffering for smooth playback. The stream
is compatible with any RTP client (VLC, Wireshark, etc.).

**Why 24 kHz?** The ICS-43434 requires 64 SCK cycles per WS frame (32-bit channel
slots). Setting `bits_per_channel: 32bit` in ESPHome satisfies this requirement and
eliminates I2S framing clicks, but halves the effective sample rate from 48 kHz to
24 kHz at the current SCK frequency. 24 kHz is sufficient for BirdNET — bird calls
are well below the 12 kHz Nyquist limit.

---

## ESP32 ESPHome Configuration

Key microphone settings: see [esphome/base.yaml](esphome/base.yaml)

Per-device overrides (board, pins, secrets): see [esphome/esp32-s3-ics43434.yaml](esphome/esp32-s3-ics43434.yaml)
(example device YAML — copy and adjust for your own board/secrets). This file
references `base.yaml` via `packages:` with a pinned git tag.

**Pins:**

| Signal     | GPIO  |
|------------|-------|
| LRCLK (WS) | GPIO5 |
| BCLK (SCK) | GPIO4 |
| DIN (SD)   | GPIO6 |

**Key I2S settings:**

| Setting            | Value | Why                                                         |
|--------------------|-------|-------------------------------------------------------------|
| `sample_rate`      | 48000 | ESPHome I2S clock base rate                                 |
| `bits_per_channel` | 32bit | Matches ICS-43434 requirement of 64 SCK/frame               |
| `bits_per_sample`  | 16bit | Truncates 24-bit mic data to 16-bit; matches RTP L16 format |
| `channel`          | left  | ICS-43434 LR pin tied low                                   |
| `use_apll`         | true  | Audio PLL for accurate clock generation                     |

**WiFi settings:**

| Setting           | Value | Why                                           |
|-------------------|-------|-----------------------------------------------|
| `power_save_mode` | none  | Disables WiFi power save to reduce UDP jitter |

The following are configurable at runtime via Home Assistant entities
(changes take effect immediately, no reflash needed):

| Entity            | Default | Description                                    |
|-------------------|---------|------------------------------------------------|
| `Audio Target IP` | (empty) | IP address to send RTP packets to              |
| `UDP Target Port` | 5000    | UDP port for RTP stream                        |
| `Mic Gain`        | 1       | Digital gain multiplier (1–32); 8 ≈ 18dB boost |

The microphone starts and stops automatically with WiFi connection state.

Each RTP packet contains 720 mono samples (30ms of audio) with a 12-byte
RTP header, totalling 1452 bytes — well under the 1500-byte MTU.
`MSG_DONTWAIT` is used on `sendto()` to prevent the WiFi TX buffer from
blocking the I2S callback.

---

## Raspberry Pi Setup

### 1. Load the ALSA Loopback Module

The loopback acts as a virtual sound card — ffmpeg writes to one side, BirdNET reads from the other.

```bash
sudo modprobe snd-aloop pcm_substreams=1
```

Make it persistent across reboots:

```bash
echo "snd-aloop" | sudo tee -a /etc/modules
echo "options snd-aloop pcm_substreams=1" | sudo tee /etc/modprobe.d/snd-aloop.conf
```

Verify it loaded:

```bash
aplay -l | grep -i loopback
# Should show: card X: Loopback [Loopback]
```

---

### 2. Disable WiFi Power Management

WiFi power save causes severe packet jitter (100ms+ gaps followed by bursts).
Disable it and make it persistent:

```bash
sudo iwconfig wlan0 power off
# Persist across reboots:
(sudo crontab -l 2>/dev/null; echo "@reboot /sbin/iwconfig wlan0 power off") | sudo crontab -
```

---

### 3. Deploy the Bridge Files

Copy the SDP file and wrapper script to the Pi:

```bash
sudo mkdir -p /opt/birdnet-audio-bridge
sudo cp birdnetpi/stream.sdp /opt/birdnet-audio-bridge/stream.sdp
sudo cp birdnetpi/birdnet_audio_bridge.sh /opt/birdnet-audio-bridge/birdnet_audio_bridge.sh
sudo chmod +x /opt/birdnet-audio-bridge/birdnet_audio_bridge.sh
```

The SDP file tells ffmpeg the format of the RTP stream. If the ESP32
sends to a specific unicast IP, edit the `c=` line in `stream.sdp` to
match the ESP32's IP. If using broadcast or if unsure, leave it as
`0.0.0.0` to accept from any source.

The wrapper script drains any stale UDP packets queued before starting
ffmpeg (prevents an initial RTP buffer overflow) and then runs the
ffmpeg→ALSA pipeline.

---

### 4. Install the systemd Service

```bash
sudo cp birdnetpi/birdnet_audio_bridge.service /etc/systemd/system/birdnet_audio_bridge.service
```

See [birdnetpi/birdnet_audio_bridge.service](birdnetpi/birdnet_audio_bridge.service).
The service runs the wrapper script, which handles UDP drain and the ffmpeg pipeline.

**Filter chain explained:**

| Filter                                   | Purpose                                             |
|------------------------------------------|-----------------------------------------------------|
| `aresample=48000:async=1000:first_pts=0` | Upsample 24kHz→48kHz; insert silence on packet loss |
| `volume=1`                               | Unity gain (adjust ESP32 `Mic Gain` via HA instead) |
| `highpass=f=100`                         | Remove low-frequency wind/rumble noise              |
| `lowpass=f=11500`                        | Cut above bird call frequencies (Nyquist is 12kHz)  |
| `afftdn=nf=-25`                          | FFT-based noise reduction (removes background hiss) |

The output goes to `plughw:Loopback,0`, which handles automatic sample format
conversion to match the loopback device.

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable birdnet_audio_bridge
sudo systemctl start birdnet_audio_bridge
sudo systemctl status birdnet_audio_bridge
```

---

### 5. Configure BirdNET-Pi

In the BirdNET-Pi web interface go to **Tools → Settings → Advanced Settings** and set:

```
Audio Card: plughw:CARD=Loopback,DEV=1
```

---

## Verification

**Check RTP packets are arriving from the ESP32:**

```bash
sudo tcpdump -n udp port 5000 -c 5
# Should show packets of ~1452 bytes (12-byte RTP header + 1440-byte payload)
```

**Verify the RTP stream with ffmpeg:**

```bash
ffmpeg -protocol_whitelist file,udp,rtp -i /opt/birdnet-audio-bridge/stream.sdp -f null - 2>&1 | head -20
# Should show: Stream #0:0: Audio: pcm_s16be, 24000 Hz, mono
```

**Play the stream in VLC (optional, from any machine on the network):**

```bash
vlc rtp://@:5000
```

**Check the loopback write side is active:**

```bash
cat /proc/asound/card0/pcm0p/sub0/status
# Should show: state: RUNNING
# If "closed" or "XRUN": ESP32 is likely not sending — check UDP packets first
```

**Check BirdNET's recording service is consuming audio:**

```bash
ps aux | grep arecord
# Should show arecord reading from plughw:CARD=Loopback,DEV=1
```

**Check recordings are being created:**

```bash
ls -lht ~/BirdSongs/StreamData/ | head -5
```

**Check service logs:**

```bash
journalctl -fu birdnet_audio_bridge.service
```

---

## Troubleshooting

| Symptom                      | Cause                          | Fix                                                               |
|------------------------------|--------------------------------|-------------------------------------------------------------------|
| No RTP packets arriving      | ESP32 not sending / wrong IP   | Check `Audio Target IP` entity in Home Assistant                  |
| `state: closed` or `XRUN`    | No RTP data from ESP32         | Verify ESP32 is sending: `sudo tcpdump -n udp port 5000 -c 5`     |
| `state: OPEN` not `RUNNING`  | ffmpeg not writing to loopback | Check `systemctl status birdnet_audio_bridge`                     |
| Frequent XRUN in loopback    | Sample rate mismatch           | Verify SDP `a=rtpmap` rate matches ESP32 output rate              |
| Clicks/pops in spectrogram   | Packet loss (WiFi congestion)  | Check WiFi signal (`WiFi Signal dB` entity in HA); move closer    |
| `max delay reached` in logs  | Network jitter / packet burst  | Check WiFi signal strength; disable WiFi power save on both sides |
| Clipping warnings in logs    | Volume/gain too high           | Lower `Mic Gain` in HA (changes take effect immediately)          |
| Weak or no detections        | Volume/gain too low            | Raise `Mic Gain` in HA (changes take effect immediately)          |
| XRUN on service startup only | Normal; stale packets drained  | One-time xrun at startup is expected and harmless                 |
| `Device or resource busy`    | Another process has the device | Check `fuser /dev/snd/*`                                          |
