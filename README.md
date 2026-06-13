# Gateduino

ESPHome firmware and Home Assistant automations for the Gateduino automatic gate system — opens the gate when the Luba mower approaches, closes it when the mower leaves.

## Hardware

Three ESP32 nodes:

| Node | Role | Static IP |
|------|------|-----------|
| gateduino-front | BLE scanner, front yard | 192.168.0.200 |
| gateduino-back | BLE scanner, back yard | 192.168.0.250 |
| gateduino-gate | Gate relay controller + BLE scanner | DHCP |

**Mower BLE MAC:** `C8:FE:0F:1D:0A:F8` (Luba-VSVUUEXM)

## Architecture

```
[gateduino-front]  [gateduino-back]  [gateduino-gate]
 passive BLE scan   passive BLE scan   passive BLE scan + relay
        |                  |                  |
        +------- HA Native API (primary) ------+
        |                  |                  |
        +------- MQTT (dashboard/Hubitat) -----+
                           |
                   [Home Assistant]
                    Gate logic:
                    - Combine 3x RSSI readings
                    - Check mower state (Mammotion)
                    - Check BLE proxy state
                    - Open/close via ESPHome service
```

All gate decision logic lives in HA automations — not distributed across nodes.

## ESPHome Setup

### 1. Configure secrets

```bash
cp esphome/secrets.yaml.example esphome/secrets.yaml
# Edit secrets.yaml with your WiFi, MQTT, and API key values
# Generate API keys: esphome generate-api-key  (run 3x, one per node)
```

### 2. Flash nodes

```bash
chmod +x deploy.sh

./deploy.sh all       # flash all three nodes
./deploy.sh front     # flash one node
./deploy.sh compile all  # compile only, no flash
```

Flash front and back first — they're scanners only, gate stays closed. Then flash the gate node.

## Home Assistant Setup

### Required helper

Create a Toggle helper in HA:
- **Settings > Devices & Services > Helpers > Add Helper > Toggle**
- Name: `Gate Auto-Open Enabled`
- Entity ID: `input_boolean.gate_auto_open_enabled`

### Import blueprints

Import each blueprint via **Settings > Automations & Scenes > Blueprints > Import Blueprint** using the raw GitHub URL:

| Blueprint | URL |
|-----------|-----|
| Auto Open | `https://raw.githubusercontent.com/wavezcs/gateduino/main/blueprints/automation/gateduino/auto_open.yaml` |
| Auto Close (RSSI) | `https://raw.githubusercontent.com/wavezcs/gateduino/main/blueprints/automation/gateduino/auto_close_rssi.yaml` |
| Auto Close (Docked) | `https://raw.githubusercontent.com/wavezcs/gateduino/main/blueprints/automation/gateduino/auto_close_docked.yaml` |
| BLE Proxy Notifications | `https://raw.githubusercontent.com/wavezcs/gateduino/main/blueprints/automation/gateduino/ble_proxy_notifications.yaml` |

> **Note:** HACS does not support ESPHome device configs. Use `deploy.sh` for firmware.
> The HA blueprints above are importable via HA's native blueprint import (not HACS).

## MQTT Topics

| Topic | Description |
|-------|-------------|
| `gateduino/{node}/status` | JSON: rssiAvg, gateState, lubaPresent |
| `gateduino/{node}/config` | JSON config, published every 30s (retained) |
| `gateduino/{node}/lwt` | online/offline (retained) |
| `gateduino/{node}/log` | Log messages |
| `gateduino/gate/command` | OPEN, CLOSE, PING, RESTART |
| `gateduino/all/command` | OPEN, CLOSE, ENABLE/DISABLE_BLE_SCANNING |

## RSSI Thresholds

| Substitution | Default | Meaning |
|-------------|---------|---------|
| `trigger_rssi` | -76 dBm | Inner zone — gate opens |
| `area_rssi` | -87 dBm | Outer zone — mower approaching |

Tune in the `substitutions:` block of each node yaml, or override per-node.

## BLE Proxy Conflict

When an attic or garage BLE proxy connects to the mower, the mower stops broadcasting BLE. Scanner nodes will report unavailable. The auto-open automation checks proxy state as a condition, so auto-gate is automatically disabled while a proxy is active.

## GPIO Wiring

Boards are Seeed XIAO ESP32S3 — note the XIAO D-label to GPIO mapping (D4=GPIO5, D8=GPIO7, D10=GPIO9).

| Wire | From | To |
|------|------|----|
| Front→Gate | Front GPIO9 (XIAO D10) | Gate GPIO7 (XIAO D8) |
| Back→Gate | Back GPIO9 (XIAO D10) | Gate GPIO9 (XIAO D10) |

Gate relay: GPIO5 (XIAO D4), active-low.

These GPIO wires are hardware fallback only — used when HA is offline.

## Migration from Arduino Firmware

See [esphome/MIGRATION.md](esphome/MIGRATION.md) for the full migration guide and explanation of why the Arduino firmware was replaced.
