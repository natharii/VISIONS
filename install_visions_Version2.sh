#!/bin/bash
# INSTALL SCRIPT for VISIONS prototype
# Run on the Raspberry Pi as user 'pi':
#   chmod +x install_visions.sh
#   ./install_visions.sh
set -e

VISION_DIR="/home/pi/visions"
echo "Creating $VISION_DIR"
mkdir -p "$VISION_DIR/web_client"
chown -R pi:pi "$VISION_DIR"
cd "$VISION_DIR"

echo "Writing requirements.txt"
cat > requirements.txt <<'PYREQ'
flask
flask-socketio
eventlet
pyserial
python-dotenv
twilio
PYREQ

echo "Writing lidar_tfluna.py"
cat > lidar_tfluna.py <<'PY'
"""Simple TF-Luna reader for Raspberry Pi over /dev/serial0.

Parses TF-Luna 9-byte frame:
0x59 0x59 <dist_low> <dist_high> <strength_low> <strength_high> <temp_low> <temp_high> <checksum>

Returns distance in centimeters.
"""
import serial
import time
import logging

logger = logging.getLogger("tfluna")

class TFLuna:
    def __init__(self, port="/dev/serial0", baudrate=115200, timeout=1.0):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.ser = None

    def open(self):
        self.ser = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
        time.sleep(0.1)

    def close(self):
        if self.ser and self.ser.is_open:
            self.ser.close()

    def read_frame(self):
        """Read and parse a TF-Luna frame. Return distance_cm or None."""
        if not self.ser:
            raise RuntimeError("Serial port not open")
        # sync to 0x59 0x59
        while True:
            b = self.ser.read(1)
            if not b:
                return None
            if b == b'\x59':
                b2 = self.ser.read(1)
                if b2 == b'\x59':
                    frame = self.ser.read(7)  # remaining 7 bytes
                    if len(frame) != 7:
                        return None
                    # parse dist (little endian)
                    dist = frame[0] + (frame[1] << 8)
                    return dist  # centimeters
                # else continue searching
            # else keep searching

    def iter_distance(self):
        while True:
            try:
                d = self.read_frame()
            except Exception:
                logger.exception("TF-Luna read error")
                d = None
            yield d
PY

echo "Writing twilio_client.py"
cat > twilio_client.py <<'PY'
import os
import logging
from twilio.rest import Client

logger = logging.getLogger("twilio_client")

class TwilioClient:
    def __init__(self):
        self.sid = os.environ.get("TWILIO_ACCOUNT_SID")
        self.token = os.environ.get("TWILIO_AUTH_TOKEN")
        self.from_number = os.environ.get("TWILIO_FROM_NUMBER")
        if not all([self.sid, self.token, self.from_number]):
            logger.warning("Twilio not configured (TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER)")
            self.client = None
        else:
            self.client = Client(self.sid, self.token)

    def send_sms(self, to_number, body):
        if not self.client:
            logger.warning("Twilio client not configured, cannot send SMS")
            return None
        try:
            msg = self.client.messages.create(
                body=body,
                from_=self.from_number,
                to=to_number
            )
            logger.info("Sent SMS SID=%s to %s", msg.sid, to_number)
            return msg.sid
        except Exception:
            logger.exception("Failed to send SMS")
            return None
PY

echo "Writing logger_csv.py"
cat > logger_csv.py <<'PY'
import csv
import os
import threading
from datetime import datetime

class CSVLogger:
    def __init__(self, path="visions_log.csv"):
        self.path = path
        self.lock = threading.Lock()
        self._ensure_header()

    def _ensure_header(self):
        if not os.path.exists(self.path):
            with open(self.path, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["timestamp","event","distance_cm","motion","override","sender","details"])

    def log(self, event, distance_cm=None, motion=None, override=None, sender=None, details=""):
        with self.lock:
            with open(self.path, "a", newline="") as f:
                w = csv.writer(f)
                w.writerow([datetime.utcnow().isoformat()+"Z", event, distance_cm or "", motion if motion is not None else "", override if override is not None else "", sender or "", details])
PY

echo "Writing vision_server.py"
cat > vision_server.py <<'PY'
"""
VISIONS main service (updated to accept forwarded incoming-sender info).

Endpoints:
- GET /               -> serves web client index
- GET /client.js      -> serves client js
- POST /incoming_sms  -> accept forwarded incoming SMS data from companion app
    required header: X-VISIONS-AUTH: <INCOMING_AUTH_TOKEN>
    JSON body: { "from": "+1555...", "body": "message text" }
"""
import os
import time
import threading
import logging
from flask import Flask, send_from_directory, request, jsonify, abort
from flask_socketio import SocketIO, emit
from lidar_tfluna import TFLuna
from twilio_client import TwilioClient
from logger_csv import CSVLogger

# Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("visions")

# Config
DIST_THRESHOLD = int(os.environ.get("PHONE_DISTANCE_THRESHOLD_CM", "18"))
DEBOUNCE_SECONDS = int(os.environ.get("PHONE_DEBOUNCE_SECONDS", "5"))
AUTO_REPLY_TEXT = os.environ.get("AUTO_REPLY_TEXT", "I’m currently driving and will respond shortly.")
WEB_CLIENT_DIR = os.path.join(os.path.dirname(__file__), "web_client")
INCOMING_AUTH_TOKEN = os.environ.get("INCOMING_AUTH_TOKEN")  # required to post forwarded SMS

app = Flask(__name__, static_folder=None)
socketio = SocketIO(app, cors_allowed_origins="*")
csvlogger = CSVLogger()
tw = TwilioClient()

# Shared state
state = {
    "motion": False,
    "phone_alert": False,
    "override": False,
    "last_distance": None,
    "client_sid": None,
    "last_sender": None,  # phone number string forwarded by Android app
    "last_sender_body": None,
}

# Serve web client files
@app.route("/")
def index():
    return send_from_directory(WEB_CLIENT_DIR, "index.html")

@app.route("/client.js")
def clientjs():
    return send_from_directory(WEB_CLIENT_DIR, "client.js")

# Endpoint for forwarded incoming SMS (from Android app)
@app.route("/incoming_sms", methods=["POST"])
def incoming_sms():
    # simple token check
    token = request.headers.get("X-VISIONS-AUTH")
    if not INCOMING_AUTH_TOKEN or token != INCOMING_AUTH_TOKEN:
        abort(403)
    data = request.get_json(force=True, silent=True)
    if not data or "from" not in data:
        return jsonify({"error": "missing 'from' field"}), 400
    from_number = data["from"]
    body = data.get("body", "")
    state["last_sender"] = from_number
    state["last_sender_body"] = body
    logger.info("Received forwarded incoming SMS from %s", from_number)
    csvlogger.log("incoming_sms_forwarded", distance_cm=state["last_distance"], motion=state["motion"], override=state["override"], sender=from_number, details=body)
    # optionally notify connected web client
    socketio.emit("incoming_sms", {"from": from_number, "body": body})
    return jsonify({"status": "ok"}), 200

@socketio.on("connect")
def handle_connect():
    logger.info("Client connected")
    emit("status", {"msg": "connected", "state": state})

@socketio.on("disconnect")
def handle_disconnect():
    logger.info("Client disconnected")

@socketio.on("motion")
def handle_motion(data):
    moving = bool(data.get("moving"))
    state["motion"] = moving
    logger.info("Motion update: %s", moving)
    csvlogger.log("motion_update", distance_cm=state["last_distance"], motion=moving, override=state["override"], sender=state["last_sender"], details=str(data))

@socketio.on("override")
def handle_override(data):
    ov = bool(data.get("override"))
    state["override"] = ov
    logger.info("Override set: %s", ov)
    csvlogger.log("override", distance_cm=state["last_distance"], motion=state["motion"], override=ov, sender=state["last_sender"], details=str(data))
    emit("override_ack", {"override": ov})

def send_auto_reply(to_number):
    if not to_number:
        # fallback to configured recipient
        to_number = os.environ.get("TWILIO_RECIPIENT")
    if not to_number:
        logger.warning("No recipient configured for auto-reply")
        return None
    sid = tw.send_sms(to_number, AUTO_REPLY_TEXT)
    csvlogger.log("auto_reply_sent", distance_cm=state["last_distance"], motion=state["motion"], override=state["override"], sender=to_number, details=f"sid:{sid}")
    return sid

def notify_clients_block(on):
    socketio.emit("block", {"block": on})

def detection_loop():
    tfl = TFLuna()
    try:
        tfl.open()
    except Exception:
        logger.exception("Failed to open TF-Luna serial port")
        return

    last_phone_seen = False
    phone_debounce_ts = None

    for dist in tfl.iter_distance():
        if dist is None:
            time.sleep(0.05)
            continue
        state["last_distance"] = dist
        phone_in_hand = dist <= DIST_THRESHOLD
        now = time.time()
        if phone_in_hand and not last_phone_seen:
            phone_debounce_ts = now
        if phone_in_hand and phone_debounce_ts and now - phone_debounce_ts >= DEBOUNCE_SECONDS:
            if not state["phone_alert"]:
                state["phone_alert"] = True
                logger.info("Phone usage detected (debounced). distance=%d cm", dist)
                csvlogger.log("phone_usage_detected", distance_cm=dist, motion=state["motion"], override=state["override"], sender=state["last_sender"], details="debounced")
                if state["motion"]:
                    if not state["override"]:
                        logger.info("Blocking: vehicle moving and phone in use -> dispatch block")
                        notify_clients_block(True)
                        csvlogger.log("block_activated", distance_cm=dist, motion=state["motion"], override=state["override"], sender=state["last_sender"], details="")
                        # Prioritize forwarded sender for auto-reply
                        recipient = state.get("last_sender") or os.environ.get("TWILIO_RECIPIENT")
                        if recipient:
                            send_auto_reply(recipient)
        if not phone_in_hand:
            if state["phone_alert"]:
                logger.info("Phone usage ended")
                csvlogger.log("phone_usage_ended", distance_cm=dist, motion=state["motion"], override=state["override"], sender=state["last_sender"], details="")
            state["phone_alert"] = False
            phone_debounce_ts = None
            notify_clients_block(False)
        last_phone_seen = phone_in_hand
        time.sleep(0.01)

def run_server():
    t = threading.Thread(target=detection_loop, daemon=True)
    t.start()
    socketio.run(app, host="0.0.0.0", port=5000)

if __name__ == "__main__":
    run_server()
PY

echo "Writing web_client/index.html"
cat > web_client/index.html <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>VISIONS Companion</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <style>
    body { font-family: Arial, sans-serif; padding: 1rem; }
    .status { margin: 1rem 0; padding: 1rem; border: 1px solid #ccc; }
    button { padding: 0.6rem 1rem; margin: 0.3rem; }
    #blockOverlay { display:none; position:fixed; inset:0; background:rgba(0,0,0,0.8); color:white; align-items:center; justify-content:center; }
  </style>
</head>
<body>
  <h1>VISIONS Companion</h1>
  <div class="status">
    <div>Connection: <span id="conn">disconnected</span></div>
    <div>Vehicle moving: <span id="moving">false</span></div>
    <div>Override: <span id="override">false</span></div>
    <div>Block: <span id="block">false</span></div>
    <div>Last sender: <span id="lastSender">none</span></div>
  </div>

  <div>
    <button id="btnAllowMotion">Enable Motion Reporting</button>
    <button id="btnToggleMotion">Toggle Motion (manual)</button>
    <button id="btnOverride">Toggle Override</button>
  </div>

  <div id="blockOverlay"><h1>Phone interaction blocked — Driving</h1><p>Use override to exit.</p></div>

  <script src="/client.js"></script>
</body>
</html>
HTML

echo "Writing web_client/client.js"
cat > web_client/client.js <<'JS'
// Simple Socket.IO client for the VISIONS companion web app.

const socket = io();

const connSpan = document.getElementById("conn");
const movingSpan = document.getElementById("moving");
const overrideSpan = document.getElementById("override");
const blockSpan = document.getElementById("block");
const overlay = document.getElementById("blockOverlay");
const lastSenderSpan = document.getElementById("lastSender");

let isMoving = false;
let overrideOn = false;
let blockOn = false;

socket.on("connect", () => {
  connSpan.textContent = "connected";
});

socket.on("disconnect", () => {
  connSpan.textContent = "disconnected";
});

socket.on("status", (s) => {
  console.log("status", s);
  if (s && s.state && s.state.last_sender) {
    lastSenderSpan.textContent = s.state.last_sender;
  }
});

socket.on("block", (payload) => {
  blockOn = !!payload.block;
  blockSpan.textContent = blockOn;
  overlay.style.display = blockOn ? "flex" : "none";
});

socket.on("incoming_sms", (p) => {
  if (p && p.from) {
    lastSenderSpan.textContent = p.from;
  }
});

// buttons
document.getElementById("btnToggleMotion").addEventListener("click", () => {
  isMoving = !isMoving;
  movingSpan.textContent = isMoving;
  socket.emit("motion", { moving: isMoving });
});

document.getElementById("btnOverride").addEventListener("click", () => {
  overrideOn = !overrideOn;
  overrideSpan.textContent = overrideOn;
  socket.emit("override", { override: overrideOn });
});

document.getElementById("btnAllowMotion").addEventListener("click", async () => {
  if (typeof DeviceMotionEvent !== "undefined" && typeof DeviceMotionEvent.requestPermission === "function") {
    try {
      const res = await DeviceMotionEvent.requestPermission();
      if (res === "granted") {
        startDeviceMotion();
        alert("DeviceMotion enabled. Keep this page open to send motion updates.");
      } else {
        alert("DeviceMotion permission denied.");
      }
    } catch (e) {
      alert("DeviceMotion permission error: " + e);
    }
  } else {
    startDeviceMotion();
    alert("If your phone supports DeviceMotion, movement will now be detected while the page is open.");
  }
});

function startDeviceMotion() {
  window.addEventListener("devicemotion", (ev) => {
    if (!ev.accelerationIncludingGravity) return;
    const ax = ev.accelerationIncludingGravity.x || 0;
    const ay = ev.accelerationIncludingGravity.y || 0;
    const az = ev.accelerationIncludingGravity.z || 0;
    const mag = Math.sqrt(ax*ax + ay*ay + az*az);
    const movingNow = Math.abs(mag - 9.8) > 1.0;
    if (movingNow !== isMoving) {
      isMoving = movingNow;
      movingSpan.textContent = isMoving;
      socket.emit("motion", { moving: isMoving });
    }
  });
}
JS

echo "Writing visions.service"
cat > visions.service <<'SRV'
[Unit]
Description=VISIONS Raspberry Pi service
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/pi/visions
Environment=PYTHONUNBUFFERED=1
# Use EnvironmentFile to load env vars, or set them here
# EnvironmentFile=/home/pi/visions/.env
ExecStart=/usr/bin/python3 /home/pi/visions/vision_server.py
Restart=on-failure
User=pi

[Install]
WantedBy=multi-user.target
SRV

echo "Writing .env.example"
cat > .env.example <<'ENV'
# Copy this file to .env and edit values (or export these vars in systemd Environment)
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
TWILIO_FROM_NUMBER=+1XXXXXXXXXX
TWILIO_RECIPIENT=+1YYYYYYYYYY    # fallback recipient if no forwarded sender
INCOMING_AUTH_TOKEN=super-secret-token
AUTO_REPLY_TEXT=I’m currently driving and will respond shortly.
PHONE_DISTANCE_THRESHOLD_CM=18
PHONE_DEBOUNCE_SECONDS=5
ENV

echo "Writing README.md"
cat > README.md <<'RMD'
# VISIONS — Pi Zero W + TF-Luna + forwarded-sender support

This version supports receiving a forwarded incoming-sender from a companion Android app (or any HTTP client) at POST /incoming_sms and will send the auto-reply to that forwarded number when blocking triggers.

Important environment variables
- TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER: Twilio config
- TWILIO_RECIPIENT: fallback recipient if no forwarded sender
- INCOMING_AUTH_TOKEN: shared token required in header X-VISIONS-AUTH for POST /incoming_sms
- PHONE_DISTANCE_THRESHOLD_CM, PHONE_DEBOUNCE_SECONDS, AUTO_REPLY_TEXT

Deploy on Pi (quick commands)
1. Enable serial (/dev/serial0) via `sudo raspi-config` -> Interfacing Options -> Serial -> Disable console, enable serial hardware, then reboot.
2. Edit /home/pi/visions/.env (copy from .env.example).
3. Install python deps:
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y python3 python3-pip
   sudo pip3 install -r /home/pi/visions/requirements.txt
4. Copy systemd unit and enable:
   sudo cp /home/pi/visions/visions.service /etc/systemd/system/visions.service
   sudo systemctl daemon-reload
   sudo systemctl enable visions.service
   sudo systemctl start visions.service
   sudo journalctl -u visions -f

How to forward incoming SMS from an Android app (example)
- POST to: http://<PI_IP>:5000/incoming_sms
- Header: X-VISIONS-AUTH: <INCOMING_AUTH_TOKEN>
- JSON: { "from": "+15551234567", "body": "Hello" }

Example curl to simulate:
curl -X POST "http://<PI_IP>:5000/incoming_sms" \
  -H "Content-Type: application/json" \
  -H "X-VISIONS-AUTH: super-secret-token" \
  -d '{"from":"+15551234567","body":"Hi"}'

Wiring (TF-Luna -> Pi Zero W)
- TF-Luna VCC -> Pi 5V (or 3.3V depending on your TF-Luna module; check module docs)
- TF-Luna GND -> Pi GND
- TF-Luna TX -> Pi RX (GPIO15, physical pin 10, /dev/serial0 RX)
- TF-Luna RX -> Pi TX (GPIO14, physical pin 8, /dev/serial0 TX)

Important: If your TF-Luna UART is 5V TTL, use a level shifter for TX/RX to the Pi (3.3V).

Limitations
- Browser companion must be open to report DeviceMotion reliably (iOS/Android background limits).
- To block phone input directly you need a native app on the phone (Android allows stronger enforcement).
RMD

echo "Setting permissions"
chmod +x install_visions.sh
chmod 644 visions.service
chown -R pi:pi "$VISION_DIR"

echo "Done. Review /home/pi/visions/.env.example, copy to .env, edit, enable serial in raspi-config, then run the steps in README.md to install deps and enable the service."