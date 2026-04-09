# ESP32 Microphone → BirdNET-Pi Audio Bridge

Streams audio from a Waveshare ESP32-S3 Zero with an ICS-43434 I2S microphone to a headless Raspberry Pi running
BirdNET-Pi, via raw UDP over the local network.

---

## Architecture

```
ICS-43434 mic
     │ I2S (32-bit slots, left channel, 24kHz effective)
ESP32-S3 Zero
     │ raw stereo PCM UDP (port 5000)
     ▼
Raspberry Pi (BirdNET-Pi)
  ffmpeg (24kHz→48kHz upsample) → ALSA Loopback → BirdNET-Pi recording service
```

**Audio format sent over UDP:** 16-bit signed PCM, little-endian, stereo, ~24 kHz.

The ICS-43434 outputs 24-bit data in the left slot of a standard stereo I2S frame
(LR pin tied low). ESPHome's `on_data` callback delivers stereo interleaved 16-bit
LE bytes (both channels identical). The raw stereo data is sent directly over UDP
with no processing on the ESP32 to keep the I2S callback as fast as possible.
ffmpeg on the Pi handles upsampling to 48 kHz for BirdNET.

**Why 24 kHz?** The ICS-43434 requires 64 SCK cycles per WS frame (32-bit channel
slots). Setting `bits_per_channel: 32bit` in ESPHome satisfies this requirement and
eliminates I2S framing clicks, but halves the effective sample rate from 48 kHz to
24 kHz at the current SCK frequency. 24 kHz is sufficient for BirdNET — bird calls
are well below the 12 kHz Nyquist limit.

**Why stereo?** Extracting mono on the ESP32 adds processing time to the
time-critical I2S DMA callback and can cause audio glitches. Sending raw stereo
and letting ffmpeg handle it on the Pi (which has CPU to spare) produces cleaner
audio. The bandwidth cost (~1.5 Mbps) is trivial for local WiFi.

---

## ESP32 ESPHome Configuration

Key microphone settings: see [esp32-s3-ics43434.yaml](esp32-s3-ics43434.yaml)

**Pins:**

| Signal     | GPIO  |
|------------|-------|
| LRCLK (WS) | GPIO5 |
| BCLK (SCK) | GPIO4 |
| DIN (SD)   | GPIO6 |

**Key I2S settings:**

| Setting            | Value | Why                                                        |
|--------------------|-------|------------------------------------------------------------|
| `sample_rate`      | 48000 | ESPHome I2S clock base rate                                |
| `bits_per_channel` | 32bit | Matches ICS-43434 requirement of 64 SCK/frame              |
| `bits_per_sample`  | 16bit | Truncates 24-bit mic data to 16-bit (sufficient for birds) |
| `channel`          | left  | ICS-43434 LR pin tied low                                  |
| `use_apll`         | true  | Audio PLL for accurate clock generation                    |
| `power_save_mode`  | none  | Disables WiFi power save to reduce UDP jitter              |

The UDP target IP and port are configurable at runtime via Home Assistant
(`Audio Target IP` and `UDP Target Port` entities). The microphone starts
and stops automatically with WiFi connection state.

UDP packets are split into chunks of 1400 bytes or less to avoid IP
fragmentation (MTU 1500). `MSG_DONTWAIT` is used on `sendto()` to prevent
the WiFi TX buffer from blocking the I2S callback.

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

### 3. Create the systemd Service

```bash
sudo nano /etc/systemd/system/birdnet_audio_bridge.service
```

see [birdnet_audio_bridge.service](birdnet_audio_bridge.service)

**Filter chain explained:**

| Filter                                | Purpose                                            |
|---------------------------------------|----------------------------------------------------|
| `aresample=48000:async=1:first_pts=0` | Upsample 24kHz→48kHz; fill silence during UDP gaps |
| `volume=10`                           | Amplify quiet MEMS mic signal (tune to taste)      |
| `highpass=f=100`                      | Remove low-frequency wind/rumble noise             |
| `lowpass=f=11500`                     | Cut above bird call frequencies (Nyquist is 12kHz) |

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable birdnet_audio_bridge
sudo systemctl start birdnet_audio_bridge
sudo systemctl status birdnet_audio_bridge
```

---

### 4. Configure BirdNET-Pi

In the BirdNET-Pi web interface go to **Tools → Settings → Advanced Settings** and set:

```
Audio Card: plughw:CARD=Loopback,DEV=1
```

---

## Verification

**Check UDP packets are arriving from the ESP32:**

```bash
sudo tcpdump -n udp port 5000 -c 5
# Should show packets of ~1400 bytes (chunked to avoid IP fragmentation)
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

| Symptom                     | Cause                          | Fix                                                           |
|-----------------------------|--------------------------------|---------------------------------------------------------------|
| No UDP packets arriving     | ESP32 not sending / wrong IP   | Check `Audio Target IP` entity in Home Assistant              |
| `state: closed` or `XRUN`   | No UDP data from ESP32         | Verify ESP32 is sending: `sudo tcpdump -n udp port 5000 -c 5` |
| `state: OPEN` not `RUNNING` | ffmpeg not writing to loopback | Check `systemctl status birdnet_audio_bridge`                 |
| Frequent XRUN in loopback   | Sample rate mismatch           | Verify `-ar` in service matches actual ESP32 output rate      |
| Clicks/pops in spectrogram  | I2S DMA boundary artifacts     | Normal at low levels; shouldn't affect BirdNET detections     |
| Clipping warnings in logs   | Volume too high                | Decrease `volume=` value                                      |
| Weak or no detections       | Volume too low                 | Increase `volume=` value                                      |
| `Device or resource busy`   | Another process has the device | Check `fuser /dev/snd/*`                                      |
