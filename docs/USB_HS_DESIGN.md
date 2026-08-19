# High-speed USB for the metronome: ULPI PHY + byte-parallel SIE

Status: DESIGN. Not scheduled, not started. Written so implementation does not
begin with a week of re-derivation.

Companion to `docs/USB_THEORY.md` (full-speed, as built) and to
`exmo/protocol/METRONOME.md` (what the link carries and why).

**Read this first:** high speed is not needed for the metronome's data rate.
The requirement is ~28 kB/s each way; full-speed *isochronous* already gives
~512 kB/s. High speed buys **latency granularity** — 125 µs service instead of
1 ms — and nothing else. Build it when a control loop needs the host inside it,
not before. What follows is what it would take.


## 0. The one-paragraph summary

`Hw.USB.FSPhy` is deleted, not extended: high speed is current-mode analog and
no FPGA pad produces it. An external ULPI PHY does the line, and hands the
design **bytes at 60 MHz**. That makes the PHY layer *smaller* — NRZI, bit
stuffing, clock recovery, SYNC and EOP all leave the fabric. The work lands
entirely in `Hw.USB.SIE`, which is bit-serial today and must become
byte-parallel, taking `Hw.USB.CRC16` and `Hw.USB.CRC5` with it. Everything
above `Hw.Interface.USBEndpointIn`/`Out` is untouched.


## 1. Component decomposition

New:

```
Hw.USB.ULPI          — link-side ULPI: turnaround, RX CMD decode, TX CMD, reg access
Hw.USB.CRC16Byte     — 8 chained Hw.USB.CRC16 steps, combinational
Hw.USB.CRC5Byte      — 8 chained Hw.USB.CRC5 steps, combinational
Hw.USB.SIE2          — byte-parallel SIE, HS protocol
Hw.Sim.ULPIHost      — host model driving the ULPI pins
```

Unchanged, and this is the point:

```
Hw.Interface.USBEndpointIn     already byte-oriented
Hw.Interface.USBEndpointOut    already byte-oriented
Hw.USB.VendorInterrupt         enumeration + descriptors  (715 lines)
Hw.USB.CDCSerial               (742 lines)
Hw.USB.CRC16 / CRC5            reused as the bit step inside the byte versions
```

Deleted:

```
Hw.USB.FSPhy       641 lines — the PHY chip does all of it
Hw.USB.ClockTrim   254 lines — the PHY sources the clock; ±2500 ppm stops existing
```

`SIE2` rather than modifying `SIE` in place: full speed stays a working,
shipped configuration, and a design opts into one or the other. Same reasoning
`Hw.PS7HP` records for not adding ports to `Hw.PS7` — a new port is a new
undriven wire in every existing instance.


## 2. Clock domains

ULPI is **PHY-sourced**: the PHY drives a 60 MHz clock into the FPGA. The whole
USB subsystem runs in that domain.

```
ulpi_clk (60 MHz, PHY-sourced)   ULPI, SIE2, endpoint buffers, descriptor engine
metronome clk                    SYNC generator, CAN controllers, trajectory ring
```

Two domains, and the crossing is **not** in the packet path. Endpoint buffers
are dual-port BRAM written in one domain and read in the other; control and
status cross via `Hw.CDC.Sync2` and `Hw.CDC.PulseSync`, which exist.

This is a change from the FS design, whose top explicitly notes *"Single clock
domain: clk_48. No CDC crossings — matches every reference USB FS
implementation."* That property cannot survive a PHY-sourced clock. Say so
loudly in the top's moduledoc rather than letting someone discover it.


## 3. `Hw.USB.ULPI`

### Ports

```elixir
clock :ulpi_clk              # 60 MHz, from the PHY
input  :rst, 1

# ULPI pins
inout  :ulpi_data,  8        # bidirectional, PHY drives when dir = 1
input  :ulpi_dir,   1
input  :ulpi_nxt,   1
output :ulpi_stp,   1

# Link-side RX
output :rx_data,    8
output :rx_valid,   1        # a payload byte is on rx_data this cycle
output :rx_active,  1        # inside a packet
output :rx_error,   1        # PHY reported a receive error
output :line_state, 2
output :rx_cmd_valid, 1      # an RX CMD updated the status outputs

# Link-side TX
input  :tx_pid,     4        # PID low nibble, used to form the TX CMD
input  :tx_data,    8
input  :tx_valid,   1
output :tx_ready,   1        # PHY accepted a byte (nxt)
input  :tx_end,     1        # assert with the last byte; drives stp

# Register access — needed for HS select, and for suspend/resume later
input  :reg_addr,   6
input  :reg_wdata,  8
input  :reg_write,  1
input  :reg_read,   1
output :reg_rdata,  8
output :reg_done,   1
```

### The three things it does

**Turnaround.** `dir` is owned by the PHY and can assert at any time. When it
rises, the link must stop driving `ulpi_data` **that cycle** and the first byte
with `dir=1, nxt=0` is an **RX CMD**, not payload. Getting this wrong is the
classic ULPI bug: treating the RX CMD as the PID.

**RX CMD decode.** `dir=1, nxt=0` → the byte is status: `LineState[1:0]`,
`VbusState[3:2]`, `RxActive[4]`, `RxError[5]`, `HostDisconnect[6]`. Decode it,
update the status outputs, do not forward it as data. `dir=1, nxt=1` → payload
byte, forward it.

**TX.** With `dir=0`, drive a **TX CMD** byte first — `0b0100_PPPP`, the PID in
the low nibble — then payload bytes, each held until `nxt`. Assert `stp` for one
cycle after the last byte. The PHY inserts SYNC and EOP; **the link supplies the
CRC**, so the last two payload bytes are CRC16 and they are ordinary bytes as
far as the PHY is concerned.

### HS selection

After reset, write ULPI Function Control (`0x04`): `XcvrSelect = 00` (HS),
`TermSelect = 0`, `OpMode = 00`. The PHY performs the chirp handshake with the
host and reports the outcome through RX CMDs. A small init FSM at the top of
`ULPI` does this once and then never touches the register path again — the
tunnel does not need it.


## 4. Byte-parallel CRC — the low-risk part

`Hw.USB.CRC16` and `Hw.USB.CRC5` are verified combinational **bit** steps with
Elixir reference implementations (`next/2`, `compute/2`). Do not rewrite the
polynomial maths. Chain them:

```elixir
defmodule Hw.USB.CRC16Byte do
  use Hw.Component
  input  :crc_in,  16
  input  :byte_in,  8
  output :crc_out, 16

  # USB sends bytes LSB-first, so bit 0 is fed first.
  for i <- 0..7 do
    instance :"step#{i}", Hw.USB.CRC16,
      crc_in:  (if i == 0, do: :crc_in, else: :"s#{i - 1}"),
      bit_in:  :"b#{i}",
      crc_out: (if i == 7, do: :crc_out, else: :"s#{i}")
  end

  comb do
    for i <- 0..7, do: var(:"b#{i}") = byte_in[i..i]
  end
end
```

Eight XOR-shift stages is a shallow combinational path; at 60 MHz on an 85F it
is not close to critical. The Elixir oracle is free —
`CRC16.compute(bits_of(byte), crc)` — so the byte version is testable against
the bit version exhaustively over all 256 × 65536 inputs if desired, and over a
random sample certainly.

Same construction for CRC5. CRC5 matters more than its size suggests: it
validates tokens, and section 6 explains why there is no time to do it serially.


## 5. `Hw.USB.SIE2` — what actually changes

### 5.1 Ports

Replace the bit-level PHY interface:

```
- input :phy_rx_valid, 1 ; input :phy_rx_data, 1
- input :phy_rx_bit0, 1  ; input :phy_rx_pid_done, 1
- output :phy_tx_data, 1 ; input :phy_tx_ready, 1
+ input :rx_data, 8      ; input :rx_valid, 1 ; input :rx_active, 1
+ output :tx_pid, 4      ; output :tx_data, 8 ; output :tx_valid, 1
+ input  :tx_ready, 1    ; output :tx_end, 1
```

`Hw.Interface.USBEndpointIn` and `USBEndpointOut` are unchanged.

### 5.2 What disappears, and it is a mercy

`bit_cnt`, `byte_shift`, and every PID-alignment mechanism. The FS SIE's own
comments record what those cost:

> BIT-0 ALIGNED ENTRY. Enter recv_pid ONLY on the PHY's rx_bit0 strobe … not on
> active&valid which could lead by 1-2 sample phases and shift leading zeros
> (the variable-offset bug that scrambled decodes).

> Without the clear, recv_pid started from the PREVIOUS packet's residue
> (measured byte_shift=0x29 at bc=0) and never assembled correctly.

**None of that class of bug exists at byte level.** ULPI delivers aligned bytes
or it delivers nothing. The HS SIE is not merely different from the FS one; it
is less treacherous in precisely the places this one bled.

### 5.3 RX FSM

States survive with the same names and new bodies — `idle`, `recv_pid`,
`recv_token`, `recv_data` — because the packet *structure* is unchanged; only
the arrival granularity is.

* `idle` → on `rx_active` rising, the first `rx_valid` byte is the PID. One
  cycle, no assembly.
* `recv_token` → two bytes, then CRC5 over the 11-bit address/endpoint field.
  With `CRC5Byte` this is two cycles.
* `recv_data` → one payload byte per cycle into the endpoint buffer, CRC16 fed
  per byte. The residual check (`0xB001`) is unchanged.
* Packet end is `rx_active` falling, not SE0.

### 5.4 TX FSM

`tx_sync` disappears entirely — the PHY inserts SYNC. What remains is: present
the PID as `tx_pid`, stream payload bytes on `tx_valid`/`tx_ready`, append the
two CRC16 bytes, assert `tx_end` with the last one.

Bit stuffing is gone. The stuck-TX watchdog is gone with the PHY that needed it.

### 5.5 New protocol

| | |
|---|---|
| **Microframes** | SOF every 125 µs. Anything counting frames counts 8× as often. |
| **PING / NYET** | HS flow control for control and bulk OUT. Two new handshake PIDs and one new decision: NYET when the endpoint buffer will not take another max-size packet. |
| **High-bandwidth** | **Skip it.** 2–3 transactions per microframe with DATA0/1/2/MDATA sequencing, for bandwidth nobody here needs. Omitting it removes MDATA entirely. |
| **Reset / suspend** | Delivered as RX CMD line-state changes rather than as SE0 duration. The link reacts; the PHY does the chirp. |


## 6. The timing constraint, which is the actual risk

Full speed gave the SIE **4 clocks per bit — 32 per byte**. ULPI gives it
**one clock per byte**. Every state that currently has comfortable slack has
none.

The binding number: a HS device must respond to a token within **192 bit
times**. At 480 Mbit/s that is 400 ns, and at 60 MHz that is **24 ULPI clocks**
to receive the token's two bytes, check CRC5, match the address, look up the
endpoint, decide handshake-versus-data, and begin the TX CMD.

Twenty-four clocks is enough — but only if the token path is combinational
where it can be. Concretely:

* CRC5 must be byte-parallel. A serial CRC5 needs 11 clocks on a token that
  arrived in 2, leaving nothing.
* Address match and endpoint lookup should be `comb` off the latched token, not
  a sequenced walk.
* The IN-buffer-loaded decision must already be settled when the token lands —
  it cannot involve a round trip to the endpoint layer.

This is the part that does not port. Budget for it explicitly, and measure it in
simulation before silicon.


## 7. The metronome's channels

From `exmo/protocol/METRONOME.md`, six endpoints in two alternate settings:

```
altsetting 0 — commissioning
  EP0        control     enumeration, vendor requests
  EP3 OUT    bulk 512    SDO / LSS / NMT tunnel down
  EP4 IN     bulk 512    tunnel up: responses, EMCY, heartbeat
  EP5 IN     interrupt   status and faults

altsetting 1 — operational (adds the streams)
  EP1 OUT    isoc        trajectory windows
  EP2 IN     isoc        feedback
```

Alternate settings are not decoration: isochronous bandwidth is reserved at
`SET_INTERFACE`, and a device declaring isoc in altsetting 0 can fail
enumeration on a busy bus. The same switch is the commissioning-versus-
operational mode the controller needs anyway.

### Sizing

A window is 56 bytes (six axes × `pos i32 + vel i16 + status u16`, plus header).
So **isoc MPS 64 is sufficient** — the ring, not the packet, carries depth.

Service interval should equal the control period. HS encodes it as
`2^(bInterval-1)` microframes:

| control rate | period | microframes | `bInterval` |
|---|---|---|---|
| 500 Hz | 2 ms | 16 | 5 |
| 250 Hz | 4 ms | 32 | 6 |

Bulk MPS at HS **must be exactly 512**. Interrupt IN can stay small.

### The isochronous semantic conflict — fix it deliberately

`Hw.Interface.USBEndpointIn` documents:

> If the host NAKs or the ACK is lost, SIE retransmits on the next IN token
> automatically (data is still buffered).

**That is wrong for isochronous.** There is no ACK, and stale data must be
*replaced* at the next interval, never resent — a retransmitted trajectory
window is exactly the failure isoc was chosen to prevent. The interface needs a
per-endpoint mode where:

* `done` pulses **on transmission**, not on acknowledgement;
* an unloaded buffer transmits a **zero-length packet** rather than NAKing;
* the data toggle is not maintained (DATA0 always, without high-bandwidth).

Do this as an explicit `isoc` flag on the endpoint configuration, not as a
special case buried in the FSM.


## 8. Descriptors

`Hw.USB.VendorInterrupt` needs new descriptor bytes, not new structure:

* `bcdUSB = 0x0200` (already correct);
* a **device qualifier** descriptor and an **other-speed configuration**
  descriptor — required of any HS-capable device, and the usual omission;
* two interface descriptors for the alternate settings;
* endpoint descriptors with `bmAttributes` transfer type, MPS and, for isoc, the
  sync/usage type bits;
* a **BOS descriptor with Microsoft OS 2.0 descriptors** so it binds WinUSB with
  no driver.

Incidental, noted while reading: the descriptor block still carries
`bDeviceClass = 0x02` (CDC) and `idProduct = 0x0001` from the enumeration engine
it was forked from, while `Metronome.USB` asserts vendor class `0xFF` and PID
`0x0002`. The moduledoc says bring-up copy, so this is probably known.


## 9. Simulation, which is why this is tractable at all

`Hw.Sim.USBHost` bit-bangs `dp_raw`/`dn_raw` at 4 clocks per bit with NRZI and
stuffing. `Hw.Sim.ULPIHost` replaces it and is **simpler**: drive `ulpi_dir`,
`ulpi_nxt` and `ulpi_data` with bytes, emit RX CMDs, honour `stp`. No NRZI, no
stuffing, no oversampled edges, no clock recovery to model.

It must model the things that actually bite:

* `dir` turnaround including the RX CMD that precedes payload;
* `nxt` deasserted mid-packet as backpressure;
* the 192-bit-time response window, so a too-slow SIE **fails in simulation**
  rather than on a scope;
* SOF at 125 µs with microframe numbering;
* PING/NYET sequences on bulk OUT.

That third item is the one worth building first. It turns the section-6 risk
from something discovered on silicon into an assertion.


## 10. Bring-up staging

Following the repo's existing pattern of one design per proven slice:

```
designs/ulpi_bringup/          PHY reset, HS select, RX CMD decode; report line
                               state out the FTDI serial port. No SIE.
designs/usb_hs_enum/           ULPI + SIE2 + VendorInterrupt; enumerate at HS
                               against a real host. The oracle is lsusb -v
                               reporting 480 Mbit/s and a byte-correct descriptor.
designs/usb_hs_streams/        altsetting 1, isoc IN/OUT looped back in fabric,
                               bulk tunnel echoing. Measure achieved interval.
```

Only the first needs new hardware. The other two are the same board once it works.


## 11. Risks, honestly ordered

1. **The 24-clock token response budget** (§6). The only item that can make this
   not work. Simulate it before building hardware.
2. **ULPI signal integrity on ULX3S.** 12 signals at 60 MHz across the GP header
   to a breakout is the fiddliest physical part. On a purpose-built metronome
   PCB it is routine — which is an argument for not doing this on ULX3S at all.
3. **CDC between the ULPI domain and the metronome domain** (§2). The FS design
   has no clock crossings; this one must. `Hw.CDC.Sync2` and `PulseSync` exist,
   but the endpoint buffers become dual-port and that is new.
4. **PING/NYET** is genuinely new protocol rather than a port.
5. Descriptor completeness — device qualifier and other-speed config are easy to
   omit and produce enumeration failures that look like nothing else.


## 12. What this does not change

`Hw.CAN.Controller`, the cyclic engine, the SYNC generator, the trajectory ring,
and everything in `exmo`. The link is a transport. If the metronome ends up on a
Zynq carrier with AXI-DMA, none of this is needed at all — see
`exmo/protocol/METRONOME.md`, *Transports*.
