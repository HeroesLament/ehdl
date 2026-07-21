# USB Full-Stack Theory of Operation

This document explains how a correct USB 2.0 full-speed device stack is
*supposed* to work — from physics on the wire through CDC-ACM enumeration and
bulk data transfer. It is intentionally agnostic to the current state of the
EHDL implementation; use it as a specification to check the code against.

References throughout use EHDL module names (`FSPhy`, `SIE`, `CDCSerial`) to
anchor theory to our layering, but every claim here is derived from the USB 2.0
specification or well-established implementation practice, not from our code.

---

## 1. The Physical Layer — What Lives on the Wire

### 1.1 Differential signaling

USB full-speed uses a differential pair, D+ and D−. The two meaningful
states are:

| State | D+ vs D− | Meaning |
|-------|-----------|---------|
| J | D+ > D− | Idle / logic-1 in NRZI |
| K | D+ < D− | Start-of-SYNC / logic-0 in NRZI |
| SE0 | Both low | End-of-Packet, Reset |

A full-speed device signals its presence by asserting a 1.5 kΩ pull-up on
D+. The host detects this and knows a full-speed device has attached.

### 1.2 NRZI encoding

USB uses Non-Return-to-Zero Inverted (NRZI) line coding. The rule is:

- Transmitting a **0 bit** → **toggle** the line state (J→K or K→J).
- Transmitting a **1 bit** → **hold** the current line state.

A long run of 1s would produce no transitions, which makes clock recovery
impossible for the receiver. This is solved by bit stuffing.

### 1.3 Bit stuffing

After every **six consecutive 1 bits** in the data stream, the transmitter
inserts an extra 0 bit. The receiver must:

1. Count consecutive 1s in the decoded NRZI stream.
2. When it sees six in a row, discard the next bit (it is always 0 and
   carries no data).
3. If it sees *seven* consecutive 1s, that is an error.

Bit stuffing begins counting from the very first bit of the SYNC field.
The final `1` in the SYNC pattern counts as the first `1` in any subsequent
run, so a bit-stuff zero may appear as early as the second bit of the PID.

### 1.4 SYNC and EOP

Every packet starts with a **SYNC** field: the NRZI-decoded bit pattern
`00000001` (transmitted MSB-last, appearing on the wire as `KJKJKJKK`).
The two K's at the end are the marker that tells the receiver "PID starts
next." After SYNC, all data bytes are transmitted **least-significant-bit
first**.

Every packet ends with an **End-of-Packet (EOP)**:

1. Two bit-times of **SE0** (D+ and D− both held low).
2. One bit-time of **J** (return to idle).

The SE0 is never NRZI-encoded and never bit-stuffed — it is a raw electrical
state change.

### 1.5 Clock recovery and oversampling

Because the host and device run from independent oscillators, the device
must recover the host's clock from the received signal. The standard approach
is **4× oversampling**: the device samples at 4× the bit rate (48 MHz for
12 Mbit/s full-speed) and uses transitions in the NRZI stream to align the
sampling phase. In practice the device samples at phase 2 out of 0–3 (the
middle of the bit window), re-aligning on every 0-bit transition.

**`FSPhy` is responsible for everything in Section 1.** It presents a clean,
bit-stuffing-free, NRZI-decoded byte stream upward to the `SIE`.

---

## 2. The Packet Layer — Tokens, Data, Handshakes

### 2.1 Packet structure

After SYNC is stripped, every USB packet consists of:

```
[PID byte] [optional payload] [optional CRC]
```

A **PID byte** is 4 bits of packet type followed by the bitwise complement of
those 4 bits. The complement is a sanity check — a device that receives a PID
with mismatched halves must discard the packet.

### 2.2 Packet types and their PIDs

| Category | Name | PID byte |
|----------|------|----------|
| Token | OUT | 0xE1 |
| Token | IN | 0x69 |
| Token | SOF | 0xA5 |
| Token | SETUP | 0x2D |
| Data | DATA0 | 0xC3 |
| Data | DATA1 | 0x4B |
| Handshake | ACK | 0xD2 |
| Handshake | NAK | 0x5A |
| Handshake | STALL | 0x1E |

### 2.3 Token packets

Token packets tell the device which endpoint the host is addressing. They
contain:

- 7-bit device address
- 4-bit endpoint number
- 5-bit CRC5 over the address and endpoint fields

**CRC5 polynomial:** x⁵ + x² + 1. Initialized to 0x1F. A correctly received
token (address + endpoint + CRC5 field) leaves residual **0x0C** in the
running CRC.

The device must validate CRC5 before acting on any token. A token with a bad
CRC must be silently ignored.

### 2.4 Data packets

Data packets carry a payload of 0–64 bytes (for full-speed bulk/control) and
a 16-bit CRC16 computed over the payload bytes.

**CRC16 polynomial:** x¹⁶ + x¹⁵ + x² + 1 (0x8005). Initialized to 0xFFFF.
Transmitted as bitwise complement, LSB first. A correctly received data packet
(payload + CRC field) leaves residual **0x800D** in the running CRC. This is
the residual EHDL's `CRC16.valid` output checks.

Both CRCs are computed **bit by bit** over the NRZI-decoded, unstuffed bit
stream as each bit arrives. The running state is registered; the combinational
module (`CRC5`, `CRC16`) computes one step per clock.

### 2.5 Handshake packets

Handshake packets are a single PID byte — no payload, no CRC. Their purpose:

- **ACK** — packet received correctly, transaction complete.
- **NAK** — device is not ready (buffer full/empty). Host will retry.
- **STALL** — endpoint has halted; host must intervene to clear.

The device generates handshakes in response to data it has received (for OUT
and SETUP transactions) or to IN tokens when it has no data ready.

---

## 3. The Transaction Layer — Three-Phase Exchanges

USB is a **polled bus** — the host initiates every transaction. A transaction
has two or three phases:

### 3.1 IN transaction (device → host)

```
Host sends:   [IN token: addr, ep]
Device sends: [DATA0/DATA1: payload + CRC16]  (or [NAK] if empty)
Host sends:   [ACK]                            (if data received correctly)
```

If the device has no data, it sends NAK instead of a DATA packet, and the
host does not send ACK. The host retries on a future frame.

### 3.2 OUT transaction (host → device)

```
Host sends:   [OUT token: addr, ep]
Host sends:   [DATA0/DATA1: payload + CRC16]
Device sends: [ACK]   (if CRC OK and buffer ready)
              [NAK]   (if buffer full — not used for EP0)
              [STALL] (if endpoint halted)
```

### 3.3 SETUP transaction (host → device, EP0 only)

SETUP is structurally identical to OUT but uses PID `0x2D`. The device must
**always ACK** SETUP — it cannot NAK or STALL a SETUP token. A SETUP token
also automatically clears any pending data in the EP0 IN buffer and resets
the data toggle to DATA1 for the Status phase.

### 3.4 Data toggle

To detect duplicate packets, USB alternates between DATA0 and DATA1. For
control transfers (EP0):

- **Setup stage:** always DATA0.
- **Data stage:** starts at DATA1, alternates per packet.
- **Status stage:** always DATA1 (for IN status) or DATA0 (for OUT status).

For bulk endpoints (EP1 in our CDC design): each endpoint tracks its own
toggle independently, starting at DATA0 after `SET_CONFIGURATION` resets all
endpoint toggles.

The device must track the expected PID and silently discard any packet
carrying the wrong toggle bit. (The host will retransmit on the next poll.)

---

## 4. The Transfer Layer — Control, Bulk, Interrupt, Isochronous

### 4.1 Control transfers (EP0)

Control transfers are used for enumeration and class requests. They consist of
three stages:

**Setup stage:**
```
Host → Device: SETUP token + DATA0 (8 bytes: bmRequestType, bRequest, wValue,
               wIndex, wLength)
Device → Host: ACK
```

**Data stage** (optional, direction set by bmRequestType bit 7):
For GET_DESCRIPTOR the direction is IN (device → host):
```
Host → Device: IN token
Device → Host: DATA1 (first packet, up to 64 bytes)
Host → Device: ACK
Host → Device: IN token
Device → Host: DATA0 (next packet)
Host → Device: ACK
... (alternating DATA1/DATA0)
```

**Status stage** (direction opposite to Data stage, or IN if no Data stage):
```
Host → Device: IN token
Device → Host: DATA1, zero-length packet (ZLP)
Host → Device: ACK
```

The Status ZLP is how the device tells the host "I have finished processing
your request." Without it, the host will time out and consider the request
failed.

### 4.2 Bulk transfers (EP1 in/out)

Bulk transfers carry application data with error detection but no timing
guarantee. The host polls when it has bus bandwidth available.

- **EP1 OUT** (host → device): host sends DATA0/DATA1 packets, device ACKs.
  The device may NAK if its receive buffer is full.
- **EP1 IN** (device → host): host sends IN tokens, device sends DATA0/DATA1
  packets with payload, host ACKs. Device sends NAK if its buffer is empty.

Data toggle alternates each successfully acknowledged packet. A retransmission
(because ACK was lost) uses the same toggle as the previous attempt.

### 4.3 SOF packets

The host sends a Start-of-Frame (SOF) token every **1.000 ms ± 500 ppm**.
SOF packets carry an 11-bit frame number and CRC5. Devices may use SOF pulses
to discipline their local clock (the purpose of `ClockTrim`). SOF is addressed
to device address 0 / endpoint 0, but is *not* a transaction — no handshake
is expected and the device takes no action for it beyond clock recovery.

---

## 5. The Protocol Layer — Descriptors and Standard Requests

### 5.1 Descriptor hierarchy

Every USB device carries a fixed set of descriptors that describe its identity
and capabilities. They are stored in the device and returned verbatim in
response to GET_DESCRIPTOR.

```
Device Descriptor          (18 bytes)
└── Configuration Descriptor (9 bytes, one per configuration)
    ├── Interface Descriptor  (9 bytes, one per interface)
    │   ├── Endpoint Descriptor (7 bytes, one per non-EP0 endpoint)
    │   └── Class-specific functional descriptors
    └── Interface Descriptor ...
```

For CDC-ACM specifically, the descriptor tree is:

```
Device Descriptor
└── Configuration Descriptor
    ├── Interface 0 — Communications class (CDC control)
    │   ├── Header Functional Descriptor
    │   ├── Call Management Functional Descriptor
    │   ├── Abstract Control Management Functional Descriptor
    │   ├── Union Functional Descriptor
    │   └── EP2 IN — Interrupt, MPS 8 (notification endpoint)
    └── Interface 1 — CDC Data class
        ├── EP1 IN — Bulk, MPS 64
        └── EP1 OUT — Bulk, MPS 64
```

### 5.2 Standard request sequence — normal enumeration

A well-behaved host performs enumeration in roughly this order:

```
1. Bus reset (SE0 for ≥ 10 ms) — device returns to address 0, unconfigured.
2. GET_DESCRIPTOR (Device, wLength=18) — host reads full device descriptor.
3. SET_ADDRESS — host assigns a non-zero address. Device must ACK the Status
   ZLP *at address 0*, then switch to the new address before the next token.
4. GET_DESCRIPTOR (Device) — some hosts repeat this after SET_ADDRESS.
5. GET_DESCRIPTOR (Configuration, wLength=wTotalLength) — host reads the
   full configuration descriptor tree.
6. SET_CONFIGURATION — host activates configuration 1.
   Device resets all bulk endpoint data toggles to DATA0.
7. Class requests (CDC): SET_LINE_CODING, SET_CONTROL_LINE_STATE, etc.
8. Normal operation: EP1 IN/OUT bulk data, EP2 IN notifications (optional).
```

Step 3 (SET_ADDRESS) is the critical one. macOS logs a `setAddress: completed
with result code 4` when the device fails to correctly complete this exchange.
Result code 4 is `kIOReturnNotResponding` — the host sent the Status IN token
after SET_ADDRESS and received no response (or a bad response).

### 5.3 SET_ADDRESS timing — the most common failure point

SET_ADDRESS is the only standard request where the device must change its
address *after* sending the Status ZLP, not before. The exact sequence:

```
Host → Device:  SETUP (addr=0, ep=0): SET_ADDRESS, new_addr=N
Device → Host:  ACK  (at address 0)
Host → Device:  IN token (addr=0, ep=0)  ← Status phase, still at addr 0
Device → Host:  DATA1, ZLP              ← Status ZLP, ACK this
Host → Device:  ACK  (at address 0)    ← device receives this, switches addr
                                          ← NOW the device changes to addr N
Host → Device:  IN token (addr=N, ep=0) ← first token at new address
```

A device that switches its address *before* sending the Status ZLP will not
respond to the Status IN token (which is still addressed to 0), causing the
host to time out. A device that *never* switches will respond to subsequent
tokens at address N with silence. Either way the host gives up with
`failed to address device, disabling port`.

### 5.4 wLength clamping for GET_DESCRIPTOR

The host specifies how many bytes it wants in the `wLength` field of the
SETUP packet. The device must send **at most `wLength` bytes** — truncating
the descriptor if `wLength` is smaller than the full descriptor length. If
the device sends *more* than `wLength` bytes, the host will consider it a
protocol error.

Sending exactly `wLength` bytes when `wLength` equals a multiple of the
maximum packet size (64 bytes for full-speed bulk/control) requires a ZLP to
terminate the transfer — otherwise the host does not know the transfer has
ended. This is a frequent source of enumeration bugs.

---

## 6. The CDC-ACM Class Layer

### 6.1 What CDC-ACM provides

CDC-ACM (Communications Device Class, Abstract Control Model) makes the USB
device appear as a virtual serial port on the host. It requires:

- A Communications interface (Interface 0) with an Interrupt IN endpoint for
  notifications.
- A Data interface (Interface 1) with Bulk IN and Bulk OUT endpoints.

The host OS loads a built-in CDC-ACM driver (no INF/kext required on modern
systems) once the device presents a valid CDC descriptor tree.

### 6.2 Class-specific requests

After `SET_CONFIGURATION`, the host issues CDC class requests over EP0:

| Request | bmRequestType | bRequest | Description |
|---------|--------------|---------|-------------|
| SET_LINE_CODING | 0x21 | 0x20 | Host sends 7 bytes: baud rate, stop bits, parity, data bits |
| GET_LINE_CODING | 0xA1 | 0x21 | Host reads current line coding (device returns 7 bytes) |
| SET_CONTROL_LINE_STATE | 0x21 | 0x22 | wValue[0]=DTR, wValue[1]=RTS |

All of these must be responded to with a Status ZLP. `GET_LINE_CODING` also
has a Data IN stage returning 7 bytes. Devices that don't actually have a
UART can return zeroed line coding without issue.

`SET_CONTROL_LINE_STATE` is what sets the DTR and RTS signals that terminal
programs use to reset targets (e.g., the ESP32 on the ULX3S). A device that
never responds to this request will not receive DTR/RTS from the host.

### 6.3 Normal data flow after enumeration

```
Host → Device: IN token (ep=1)
  Device has data: Device → DATA0/DATA1 (up to 64 bytes)
                   Host → ACK
  Device empty:    Device → NAK
                   (host retries next frame)

Host → Device: OUT token (ep=1) + DATA0/DATA1 (up to 64 bytes)
  Device ready:  Device → ACK
  Device full:   Device → NAK  (host retries)
```

---

## 7. Layer Summary — EHDL Module Mapping

| USB specification layer | EHDL module | Key responsibilities |
|------------------------|-------------|---------------------|
| Physical (Section 1) | `Hw.USB.FSPhy` | D+/D− signaling, NRZI, bit stuffing, SE0, 4× oversampling, EOP detection |
| Packet / CRC (Sections 2, 3) | `Hw.USB.SIE` + `CRC5` + `CRC16` | SYNC strip, PID decode, CRC5 token check, CRC16 data check, ACK/NAK/STALL generation |
| Transaction (Section 3) | `Hw.USB.SIE` | Token decode, address filtering, EP buffer management, data toggle enforcement |
| Transfer / Protocol (Sections 4, 5) | `Hw.USB.CDCSerial` | Control transfer state machine, descriptor ROM, SET_ADDRESS timing, toggle tracking |
| CDC class (Section 6) | `Hw.USB.CDCSerial` | SET_LINE_CODING, SET_CONTROL_LINE_STATE, GET_LINE_CODING, bulk EP1 bridge |
| Clock discipline | `Hw.USB.ClockTrim` | SOF-disciplined DPLL, ECP5 PLL phase trim |

---

## 8. Common Failure Modes

### 8.1 `setAddress: completed with result code 4` (macOS)

This is exactly what the macOS log shows: the host cannot complete
`SET_ADDRESS`. Possible causes, in rough order of likelihood:

1. **Device switches address before Status ZLP.** The Status IN token is sent
   to address 0; if the device has already switched to N, it will not respond.
2. **Status ZLP is never sent.** The device ACKs the SETUP but never arms a
   ZLP on EP0 IN for the status phase. The host times out.
3. **Status ZLP sent at wrong toggle.** The Status phase always uses DATA1.
   If the device sends DATA0, the host may accept it or discard it depending
   on its strictness; macOS tends to be strict.
4. **CRC16 residual wrong.** If the running CRC is not correctly initialized
   or updated, the first GET_DESCRIPTOR response will have a bad CRC, the host
   will not ACK, the device will not see `ep_in_done`, and the EP0 state
   machine will be stuck when `SET_ADDRESS` arrives.
5. **ep_in_loaded held too long or too short.** If `ep_in_loaded` is deasserted
   before the SIE has finished transmitting (before `ep_in_done` pulses), the
   SIE may transmit a truncated or garbage packet.

### 8.2 Device connects but no `/dev/tty.usbmodem` appears

Enumeration succeeded through SET_CONFIGURATION but the CDC data interface
was not set up correctly, or the notification endpoint (EP2 IN) is missing
or has the wrong descriptor bytes.

### 8.3 Data loss on bulk transfers

The data toggle got out of sync. The device sent DATA1 where the host
expected DATA0 (or vice versa). The host silently drops the packet and keeps
sending IN tokens; the device keeps NAKing because it thinks it already sent
data. Both sides are stuck until the host issues a `CLEAR_FEATURE(HALT)` or
resets the device.

---

## 9. Reference PID Table

For quick lookup during debugging:

```
Token:     OUT   = 0xE1    IN    = 0x69    SOF   = 0xA5    SETUP = 0x2D
Data:      DATA0 = 0xC3    DATA1 = 0x4B
Handshake: ACK   = 0xD2    NAK   = 0x5A    STALL = 0x1E
```

PID validation: byte `P` is valid iff `(P & 0x0F) == (~(P >> 4) & 0x0F)`.

---

## 10. Timing Reference

| Event | Duration |
|-------|---------|
| Full-speed bit time | 83.3 ns (12 Mbit/s) |
| One byte (8 bits) | 667 ns |
| SOF interval | 1.000 ms ± 500 ppm |
| Bus reset (SE0) | 10–20 ms |
| Suspend (no SOF/KA) | 3 ms |
| Resume (K-state) | ≥ 20 ms |
| Device address switch (SET_ADDRESS) | Must complete before next token after Status ACK |
| 4× oversample clock at full-speed | 48 MHz |

---

*This document describes correct USB 2.0 full-speed CDC-ACM behaviour per the
USB 2.0 specification (April 2000) and the USB CDC specification (rev 1.2).
It is intended as a debugging reference for the EHDL USB stack.*