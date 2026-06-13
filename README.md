# Gateduino

**Automatic gate control for a robot mower.** Gateduino watches for a Mammotion
Luba mower over Bluetooth and automatically opens an automatic gate as the mower
approaches, then closes it once the mower has driven through — so the mower can
move between zones on its schedule without leaving the gate open.

The intelligence is **on the devices**, not in a server. Three ESP32 nodes
detect the mower over BLE, coordinate over ESP-NOW (a direct radio link, no
router or broker), and the gate node runs the whole open/close decision itself.
Home Assistant is used only for the dashboard, manual control, and tuning — if
HA, WiFi, or the network are down, the gate still works.

![Gateduino overview](docs/images/overview.jpg)

---

## How it works

```
[front node]                       [back node]
 BLE scan, front yard               BLE scan, back yard
 sends TRIGGER on approach          sends TRIGGER on approach
        \                                  /
         \-------- ESP-NOW broadcast ------/     (peer-to-peer, no WiFi needed)
                          |
                   [gate node]
                    BLE scan + gate relay (1 GPIO)
                    runs the transit state machine
                          |
                    ESPHome native API
                          |
                   [Home Assistant]   (dashboard / manual / tuning only)
```

- Each scanner node measures the mower's BLE signal strength (RSSI). When the
  mower gets close enough (configurable `Trigger RSSI`), the node fires a
  one-shot **TRIGGER** to the gate over ESP-NOW.
- The gate node opens, then tracks the **transit**: the first node to fire is
  the "entry" side; a trigger from the opposite ("exit") side as the mower
  drives through is recognized and ignored so it doesn't re-open the gate. The
  gate closes only after the mower has cleared the gate's own BLE range and a
  hold timer (`Transit Timeout`) has elapsed — so it never closes on the mower
  mid-crossing.
- If the mower's battery dies or its Bluetooth drops while in range, the RSSI
  reading is forced to "no signal" after `rssi_timeout` instead of latching the
  last value — so a stalled mower can't hold the gate open indefinitely.

---

## Bill of materials

| Qty | Item | Notes |
|-----|------|-------|
| 3 | **Seeed Studio XIAO ESP32-S3** | One per node (front, back, gate). |
| 1 | **Moonshan Gate Opener (MS-GO-1)** | The automatic gate actuator. |
| 3 | **24 V → 5 V USB-C buck converter** | Powers each XIAO from the gate's 24 V supply. |
| 1 | Relay / opto module or the XIAO GPIO driving the opener's trigger input | Gate node only. |
| — | Weatherproof enclosures, wiring | For the outdoor nodes. |

### Seeed XIAO ESP32-S3

![Seeed XIAO ESP32-S3](docs/images/xiao-esp32s3.jpg)

Thumb-sized ESP32-S3 board (dual-core 240 MHz, WiFi + BLE 5, 8 MB flash). Chosen
for its tiny footprint and, importantly, its **external u.FL antenna** — BLE
range to the mower matters, and the external antenna gives noticeably better
reception than a PCB antenna when the node is inside an enclosure.

ESPHome board id used in this project: `seeed_xiao_esp32s3`. Pin labels on the
board (D0–D10) **do not** equal the raw GPIO numbers — the only one this project
uses is **D4 = GPIO5** for the gate relay.

### Moonshan Gate Opener (MS-GO-1)

![Moonshan MS-GO-1 gate opener](docs/images/moonshan-ms-go-1.jpg)

The automatic gate actuator. The gate node drives the opener's external trigger
/ control input through one GPIO (see Wiring). The opener also provides the 24 V
that powers the nodes.

> Confirm your opener's trigger behavior against its manual: this firmware holds
> the relay **closed while the gate should be open** and releases it to close
> (a level-held "hold-open" input). If your MS-GO-1 expects a momentary toggle
> pulse instead, the firmware's relay handling needs a small change — open an
> issue / adjust the `gate_relay` logic accordingly.

### Powering the nodes from the gate (24 V → 5 V)

![24V to 5V USB-C converter](docs/images/power-converter.jpg)

The MS-GO-1 supplies 24 V. Each node is powered by a **24 V → 5 V USB-C buck
converter** wired to that supply, feeding the XIAO's USB-C port. This means no
separate adapters or batteries — the nodes run off the gate's own power.

> Run the back/front-yard nodes' power as appropriate for your runs; only the
> gate node needs to be co-located with the opener.

---

## Wiring

The **only** signal wire in the system is the gate relay on the gate node — the
front and back nodes are wireless (ESP-NOW) and need no connection to the gate.

| Gate node pin | Connects to |
|---------------|-------------|
| **GPIO5 (XIAO D4)**, active-low | Gate opener external trigger / hold-open input (via relay or opto) |
| 5 V / GND | 24 V→5 V converter output (from opener's 24 V) |

![Gate node wiring](docs/images/gate-wiring.jpg)

`active-low` means the firmware pulls the pin low to open. Use a relay or
opto-isolator rated for the opener's trigger input rather than driving it
directly from the GPIO.

---

## Firmware install

Built with [ESPHome](https://esphome.io). You need ESPHome installed
(`pip install esphome`) and the [secrets file](#1-secrets) filled in.

### 1. Secrets

```bash
cp esphome/secrets.yaml.example esphome/secrets.yaml
```
Edit `esphome/secrets.yaml` with your WiFi credentials, an OTA password, and one
API encryption key per node:
```bash
esphome generate-api-key   # run 3x → api_key_front / api_key_back / api_key_gate
```

### 2. First flash (USB, once per node)

The factory partition table is too small to OTA the full firmware directly, so
the first flash is over USB:

1. Plug the XIAO into a computer running Chrome.
2. Go to **https://web.esphome.io** → **Connect** → install the prepared
   ESP32-S3 base image and enter your WiFi.
3. From a machine with this repo, push the real config over the air:
   ```bash
   cd esphome
   esphome run gateduino-front.yaml --device 192.168.0.200
   esphome run gateduino-back.yaml  --device 192.168.0.250
   esphome run gateduino-gate.yaml  --device <gate-ip>
   ```

Flash the **front and back** nodes first (they're scanners; the gate stays
closed), then the **gate** node. After the first USB flash, all future updates
are OTA: `esphome run gateduino-<node>.yaml`.

### 3. Static IPs

Front and back use static IPs (`192.168.0.200` / `192.168.0.250`); the gate node
uses DHCP. Adjust the `manual_ip` blocks in the node YAMLs for your network.

---

## Home Assistant

The nodes connect to HA over the **native ESPHome API** (no MQTT). Add each via
**Settings → Devices & Services → ESPHome**, using its IP and API key.

Import the included dashboard at
[`ha/gateduino-dashboard.yaml`](ha/gateduino-dashboard.yaml):
**Settings → Dashboards → + Add dashboard → Edit in YAML → paste.** You get:

- a **live RSSI graph** of all three nodes,
- a **streaming Activity log** (the gate's decisions in the HA logbook),
- gate **controls** (open/close, Auto Mode),
- and all **tuning** sliders.

Manual control: the `Gate` switch, or the `open_gate` / `close_gate` services.
Turn `Auto Mode` off to disarm auto-open (e.g. while a Bluetooth proxy is using
the mower).

---

## Configuration — live-editable in HA (no reflash)

| Entity | Nodes | Meaning |
|--------|-------|---------|
| `Trigger RSSI` | all | dBm; mower this close to a node ⇒ trigger the gate |
| `Area RSSI` | all | dBm; approach threshold (dashboard zone marker) |
| `Transit Timeout` | all | s; scanner re-fire lockout + gate hold-before-close |
| `Child Cooldown` | gate | s; backstop window after a trigger is accepted |
| `BLE Scanning` | all | enable/disable mower detection |
| `Auto Mode` | gate | disarm to lock out auto-open |
| `Activity` | all | last event (streams to HA logbook) |
| `Crossing Active` / `Entry Side` | gate | transit state-machine diagnostics |

`rssi_timeout` (stale-signal decay, default 15 s) is a build-time constant in
`esphome/common.yaml` — ESPHome filter timeouts aren't runtime-settable.

RSSI is negative dBm; closer = higher (e.g. −70 is closer than −85). Tune
`Trigger RSSI` by watching the live graph as the mower drives up to each node.

---

## Repo layout

```
esphome/
  common.yaml            shared base (WiFi, BLE, ESP-NOW, HA entities)
  gateduino-front.yaml   front scanner   (node_id 1)
  gateduino-back.yaml    back scanner    (node_id 2)
  gateduino-gate.yaml    gate controller (relay + transit state machine)
  secrets.yaml.example   template for your secrets
ha/
  gateduino-dashboard.yaml   Home Assistant dashboard
docs/images/             photos referenced by this README
```

---

## Credits / history

Originally an Arduino sketch with the gate logic on the nodes; briefly moved to
Home-Assistant-side automations; now back to **on-device** logic over ESP-NOW
(the best of both — autonomous like the original, wireless and HA-observable).
See [esphome/MIGRATION.md](esphome/MIGRATION.md) for the migration notes.
