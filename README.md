# ESP32 Microphone → BirdNET-Pi Audio Bridge

Streams audio from a Waveshare ESP32-S3 Zero with an ICS-43434 I2S microphone to a headless Raspberry Pi running
BirdNET-Pi, via raw UDP over the local network.

---

## Architecture

```
ICS-43434 mic
     │ I2S (stereo hardware, left channel used)
ESP32-S3 Zero
     │ raw mono PCM UDP (port 5000)
     ▼
Raspberry Pi (BirdNET-Pi)
  ffmpeg → ALSA Loopback → BirdNET-Pi recording service
```

**Audio format sent over UDP:** 16-bit signed PCM, little-endian, mono, 48000 Hz.  
The ICS-43434 outputs stereo I2S with both channels identical — the ESP32 extracts
the left channel only before sending, halving bandwidth from ~1.5 Mbps to ~768 kbps.

---

## ESP32 ESPHome Configuration

Key microphone settings: see [esp32-s3-ics43434.yaml](esp32-s3-ics43434.yaml)

**Pins:**

| Signal     | GPIO  |
|------------|-------|
| LRCLK (WS) | GPIO5 |
| BCLK (SCK) | GPIO4 |
| DIN (SD)   | GPIO6 |

The UDP target IP and port are configurable at runtime via Home Assistant
(`Audio Target IP` and `UDP Target Port` entities). The microphone starts
and stops automatically with WiFi connection state.

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

### 2. Create the systemd Service

```bash
sudo nano /etc/systemd/system/birdnet_audio_bridge.service
```

see [birdnet_audio_bridge.service](birdnet_audio_bridge.service)

**Filter chain explained:**

| Filter                     | Purpose                                                             |
|----------------------------|---------------------------------------------------------------------|
| `volume=0.2`               | Reduce gain first to prevent clipping (ICS-43434 has a hot output)  |
| `aresample=async=50000`    | Smooth over clock drift between ESP32 and Pi                        |
| `highpass=f=100`           | Remove low-frequency wind/rumble noise                              |
| `lowpass=f=11500`          | Cut I2S artifact line at ~11.5kHz (above all bird call frequencies) |
| `pan=stereo\|c0=c0\|c1=c0` | Upmix mono to stereo (required by ALSA loopback)                    |

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable birdnet_audio_bridge
sudo systemctl start birdnet_audio_bridge
sudo systemctl status birdnet_audio_bridge
```

---

### 3. Configure BirdNET-Pi

In the BirdNET-Pi web interface go to **Tools → Settings → Advanced Settings** and set:

```
Audio Card: plughw:CARD=Loopback,DEV=1
```

---

## Verification

**Check UDP packets are arriving from the ESP32:**

```bash
sudo tcpdump -n udp port 5000 -c 5
```

**Check the loopback write side is active:**

```bash
cat /proc/asound/card0/pcm0p/sub0/status
# Should show: state: RUNNING
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

| Symptom                         | Cause                          | Fix                                              |
|---------------------------------|--------------------------------|--------------------------------------------------|
| No UDP packets arriving         | ESP32 not sending / wrong IP   | Check `Audio Target IP` entity in Home Assistant |
| `state: OPEN` not `RUNNING`     | ffmpeg not writing to loopback | Check `systemctl status birdnet_audio_bridge`    |
| Black bars in spectrogram       | UDP packet loss / clock drift  | Increase `fifo_size` or `async` value            |
| Clipping warnings in logs       | Mic gain too high              | Decrease `volume=` value (try `0.1`)             |
| Weak or no detections           | Mic gain too low               | Increase `volume=` value (try `0.4`)             |
| `Device or resource busy`       | Another process has the device | Check `fuser /dev/snd/*`                         |
| `cannot set channel count to 1` | ALSA loopback requires stereo  | Ensure `pan=stereo` filter is last in chain      |
