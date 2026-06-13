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
- Invalid (non-finite) RSSI readings are rejected before they can fire a
  trigger, so a momentary sensor glitch can't spuriously open the gate.

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

> The MS-GO-1 uses a level-held "hold-open" trigger input: this firmware holds
> the relay **closed while the gate should be open** and releases it to close.
> If you adapt this to a different opener that expects a momentary toggle pulse,
> the `gate_relay` handling needs a small change.

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

### 1. Configure your install (`secrets.yaml`)

```bash
cp esphome/secrets.yaml.example esphome/secrets.yaml
```

`esphome/secrets.yaml` is **gitignored** — your credentials are never committed.
Fill in every value:

| Secret | What it is |
|--------|------------|
| `wifi_ssid` / `wifi_password` | Your **2.4 GHz** WiFi (the XIAO is 2.4 GHz only). |
| `luba_mac` | Your mower's **BLE MAC** — how every node identifies the mower. |
| `ota_password` | Password for over-the-air firmware updates. **Set your own.** |
| `fallback_password` | Password for each node's fallback hotspot. **Set your own.** |
| `api_key_front` / `_back` / `_gate` | One native-API encryption key per node. |

Generate the three API keys:
```bash
esphome generate-api-key   # run 3× → api_key_front / api_key_back / api_key_gate
```

**Finding your mower's BLE MAC:** scan with a phone BLE app (e.g. nRF Connect),
or flash a node and watch its logs with `BLE Scanning` on. The **MAC** (not the
BLE name) is used because the mower stops advertising its name once a Bluetooth
proxy connects. It's bound at compile time, so changing `luba_mac` later needs a
reflash.

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

### 3. Static IPs (set for your own network)

The example configs give the **front** and **back** scanners static IPs
(`192.168.0.200` / `192.168.0.250`) so OTA always finds them; the **gate** node
uses DHCP. **These IPs are just examples** — edit the `manual_ip` block (plus
`gateway` / `subnet`) in `gateduino-front.yaml` and `gateduino-back.yaml` to fit
your LAN, then use those addresses in the `--device` flags above. If your network
resolves mDNS you can also just use `gateduino-front.local`, etc.

---

## Home Assistant

The nodes connect to HA over the **native ESPHome API** (no MQTT). Add each via
**Settings → Devices & Services → ESPHome**, using its IP and API key.

Import the included dashboard at
[`ha/gateduino-dashboard.yaml`](ha/gateduino-dashboard.yaml):
**Settings → Dashboards → + Add dashboard → Edit in YAML → paste.** You get:

- a **live RSSI graph** of all three nodes,
- a **streaming Activity log** (the gate's decisions in the HA logbook),
- gate **controls** (Momentary Open, Hold Open, Auto Mode, raw relay),
- and all **tuning** sliders.

### Manual control

Every control is also exposed as an ESPHome entity/service, so you can drive the
gate from HA, automations, or another hub (e.g. Hubitat via the HA bridge):

- **Momentary Open** — open now and auto-close after `Manual Open Duration`
  seconds. Available as the *Momentary Open* button and the `open_gate` service.
  If **Hold Open** is engaged, pressing Momentary instead **cancels the hold and
  closes** the gate — so the button acts as a toggle while held.
- **Hold Open** — keep the gate open indefinitely until released; mower-proximity
  triggers are ignored while it's on. Turn it off (or press Momentary) to close.
- **Gate** — the raw relay switch; the `close_gate` service force-closes.
- **Auto Mode** — disarm to lock out auto-open while leaving the gate **closed**
  (e.g. while a Bluetooth proxy is using the mower, or during maintenance).

For end-to-end testing without the mower, each scanner has a **Test Trigger**
diagnostic button that fires a real ESP-NOW trigger. ⚠️ It physically actuates
the gate — it is **not** a dry run. To exercise the radio without moving the
gate, turn `Auto Mode` off first.

---

## Configuration — live-editable in HA (no reflash)

| Entity | Nodes | Meaning |
|--------|-------|---------|
| `Trigger RSSI` | all | dBm; mower this close to a node ⇒ trigger the gate |
| `Area RSSI` | all | dBm; approach threshold (dashboard zone marker) |
| `Transit Timeout` | all | s; scanner re-fire lockout + gate hold-before-close |
| `Child Cooldown` | gate | s; backstop window after a trigger is accepted |
| `Manual Open Duration` | gate | s; how long Momentary Open stays open before auto-closing |
| `BLE Scanning` | all | enable/disable mower detection |
| `Auto Mode` | gate | disarm to lock out auto-open (gate stays closed) |
| `Hold Open` | gate | keep gate open until released; ignores triggers while on |
| `Activity` | all | last event (streams to HA logbook) |
| `Crossing Active` / `Entry Side` | gate | transit state-machine diagnostics |

`rssi_timeout` (stale-signal decay, default 15 s) is a build-time constant in
`esphome/common.yaml` — ESPHome filter timeouts aren't runtime-settable.

### Tuning the thresholds

RSSI is negative dBm and **closer = higher** (−70 is closer than −85). Start from
the defaults and adjust on the live RSSI graph as the mower drives up to a node:

- **`Trigger RSSI`** (default −76) — how close the mower must be to a scanner
  before it fires the gate. Too high (e.g. −60) → the gate opens late, only when
  the mower is right at the node; too low (e.g. −90) → it opens from far away or
  on stray reflections. Drive the mower to the spot where you want the gate to
  *start* opening, read the RSSI there, and set `Trigger RSSI` to it.
- **`Area RSSI`** (default −87) — a looser "approaching" threshold used only as a
  dashboard zone marker; keep it a bit lower (farther) than `Trigger RSSI`.
- **`Transit Timeout`** (default 10 s) — after a trigger, how long the gate holds
  open before it may close, and the per-scanner re-fire lockout. Raise it if your
  mower is slow through the gate; lower it for a snappier close.
- **`Child Cooldown`** (gate, default 30 s) — backstop window that ignores repeat
  triggers right after one is accepted, so a single crossing is de-bounced.
- **`Manual Open Duration`** (gate, default 15 s) — how long *Momentary Open*
  holds before auto-closing.

---

## Home Assistant blueprints (optional)

The gate runs its open/close logic **on-device**, so it works with no HA
automations at all. These optional blueprints (in
[`blueprints/automation/gateduino/`](blueprints/automation/gateduino)) add
HA-side conveniences on top:

| Blueprint | What it does |
|-----------|--------------|
| **Auto Open** (`auto_open.yaml`) | HA-side open when the mower is `mowing` and approaching — an alternative/backup to the on-device auto-open; checks an enable-toggle and optional BLE-proxy conditions first. |
| **Auto Close — Mower Gone** (`auto_close_rssi.yaml`) | Close once all scanners stay below `Area RSSI` for a delay. |
| **Auto Close — Mower Docked** (`auto_close_docked.yaml`) | Close shortly after the mower returns to its dock. |

### Deploy a blueprint

Home Assistant imports blueprints straight from a GitHub URL — **no HACS needed.**
Easiest is the one-click import links:

- [Import **Auto Open**](https://my.home-assistant.io/redirect/blueprint_import/?blueprint_url=https%3A%2F%2Fgithub.com%2Fwavezcs%2Fgateduino%2Fblob%2Fmain%2Fblueprints%2Fautomation%2Fgateduino%2Fauto_open.yaml)
- [Import **Auto Close — Mower Gone**](https://my.home-assistant.io/redirect/blueprint_import/?blueprint_url=https%3A%2F%2Fgithub.com%2Fwavezcs%2Fgateduino%2Fblob%2Fmain%2Fblueprints%2Fautomation%2Fgateduino%2Fauto_close_rssi.yaml)
- [Import **Auto Close — Mower Docked**](https://my.home-assistant.io/redirect/blueprint_import/?blueprint_url=https%3A%2F%2Fgithub.com%2Fwavezcs%2Fgateduino%2Fblob%2Fmain%2Fblueprints%2Fautomation%2Fgateduino%2Fauto_close_docked.yaml)

Or manually: **Settings → Automations & Scenes → Blueprints → Import Blueprint**
and paste the raw file URL, e.g.
`https://github.com/wavezcs/gateduino/blob/main/blueprints/automation/gateduino/auto_open.yaml`.

After importing, **create an automation** from the blueprint and select your
entities (mower, gate switch, scanner RSSI sensors). The **Auto Open** blueprint
also needs an `input_boolean.gate_auto_open_enabled` helper as its master toggle.

### HACS

This repo ships a `hacs.json`, so it can be added under **HACS → ⋮ → Custom
repositories** for discovery and update notifications. Note that HACS does **not**
flash ESPHome firmware or natively install blueprints — flash the firmware with
ESPHome (above) and add the blueprints with HA's built-in **Import Blueprint**
(also above). HACS is therefore optional here; the import links are the simplest
path.

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
blueprints/automation/gateduino/   optional HA blueprints (auto open/close)
docs/images/             photos referenced by this README
```

---

## Credits / history

Originally an Arduino sketch with the gate logic on the nodes; briefly moved to
Home-Assistant-side automations; now back to **on-device** logic over ESP-NOW
(the best of both — autonomous like the original, wireless and HA-observable).
