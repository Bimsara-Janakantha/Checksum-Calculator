# Packet Checksum Calculator

A synthesizable Verilog packet checksum calculator with an AXI-Stream-like `valid`/`ready` interface.

The design accepts 8-bit packet data, calculates the checksum by adding all bytes in a packet modulo 256, and produces one checksum byte when the final packet byte is marked with `s_axis_tlast`.

## Features

- 8-bit packet data path
- AXI-Stream-like input handshake
- AXI-Stream-like checksum output handshake
- Single-byte packet support
- Multi-byte packet support
- Consecutive packet support
- Input valid gaps
- Output backpressure handling
- 8-bit modulo-256 checksum calculation
- One checksum result for every accepted packet
- Registered checksum output
- Output data stability during backpressure
- Self-checking Verilog testbench
- Directed and randomized verification scenarios
- Scoreboard-based result checking
- Protocol monitoring
- Input and output coverage counters

## Repository Structure

| File | Description |
| --- | --- |
| [`packet_checksum.v`](./packet_checksum.v) | Synthesizable packet checksum calculator RTL |
| [`tb.v`](./tb.v) | Self-checking Verilog testbench |
| [`LICENSE`](./LICENSE) | MIT license |

## Checksum Algorithm

For every packet, the checksum is calculated as:

```text
checksum = (byte[0] + byte[1] + ... + byte[N-1]) modulo 256
```

Any carry beyond eight bits is discarded.

For example:

```text
0xFF + 0x01 = 0x100
```

The resulting eight-bit checksum is:

```text
0x00
```

## Module Interface

```verilog
module packet_checksum (
    input wire          clk,
    input wire          rst_n,

    // Packet input
    input wire [7:0]    s_axis_tdata,
    input wire          s_axis_tvalid,
    output wire         s_axis_tready,
    input wire          s_axis_tlast,

    // Checksum output
    output reg [7:0]    checksum_data,
    output reg          checksum_valid,
    input wire          checksum_ready
);
```

## Interface Signals

| Signal | Direction | Width | Description |
| --- | --- | ---: | --- |
| `clk` | Input | 1 | Rising-edge clock |
| `rst_n` | Input | 1 | Active-low asynchronous reset |
| `s_axis_tdata` | Input | 8 | Input packet byte |
| `s_axis_tvalid` | Input | 1 | Indicates that input data is valid |
| `s_axis_tready` | Output | 1 | Indicates that the DUT can accept input data |
| `s_axis_tlast` | Input | 1 | Asserted with the final byte of a packet |
| `checksum_data` | Output | 8 | Calculated checksum |
| `checksum_valid` | Output | 1 | Indicates that a checksum is available |
| `checksum_ready` | Input | 1 | Indicates that the receiver can accept the checksum |

## Input Handshake

An input byte is accepted only when both `s_axis_tvalid` and `s_axis_tready` are asserted:

```verilog
s_axis_tvalid && s_axis_tready
```

The input source must keep the following signals stable while the DUT is not ready:

```verilog
s_axis_tvalid == 1'b1
s_axis_tready  == 1'b0
```

During this condition, `s_axis_tdata` and `s_axis_tlast` must not change.

## Output Handshake

A checksum is transferred to the downstream receiver only when both `checksum_valid` and `checksum_ready` are asserted:

```verilog
checksum_valid && checksum_ready
```

When the receiver is stalled:

```verilog
checksum_valid == 1'b1
checksum_ready  == 1'b0
```

the DUT keeps the following output stable:

```verilog
checksum_data
checksum_valid
```

The checksum must remain unchanged until the downstream receiver accepts it.

## RTL Architecture

The current implementation contains:

1. An 8-bit accumulator for the current packet.
2. A registered checksum output.
3. A `checksum_valid` flag.
4. Input backpressure logic.
5. A one-entry output buffer.

The input ready signal is generated using:

```verilog
assign s_axis_tready = !checksum_valid || checksum_ready;
```

This means the DUT can accept input data when:

- No checksum is currently pending, or
- The current checksum is being consumed during the same cycle.

When the final packet byte is accepted:

1. The final byte is added to the accumulator.
2. The calculated checksum is stored in `checksum_data`.
3. `checksum_valid` is asserted.
4. The accumulator is cleared for the next packet.

## Buffering and Backpressure

The current RTL uses a one-entry registered output buffer.

The output register stores a completed checksum until the downstream receiver accepts it. If `checksum_ready` is deasserted, the DUT:

- Keeps `checksum_valid` asserted.
- Keeps `checksum_data` stable.
- Stops accepting new input when the output buffer cannot accept another result.
- Prevents the current checksum from being overwritten.

This provides safe ready/valid behavior and prevents checksum loss.

The output buffer is effectively full when:

```verilog
checksum_valid == 1'b1
checksum_ready  == 1'b0
```

When this condition occurs, input backpressure is applied through `s_axis_tready`.

## Skid Buffer Behavior

The current design does not contain a separate module named `skid_buffer`. Instead, it uses a registered one-entry output buffer with direct backpressure propagation.

Functionally, this provides a limited elastic-buffer behavior:

- A completed checksum is captured into a register.
- The checksum remains stored while the receiver is stalled.
- The valid signal remains asserted until the result is transferred.
- The input interface is stopped when the storage register is occupied.

The basic storage behavior is:

```text
Output buffer empty:
    checksum_valid = 0
    Input may be accepted

Packet completes:
    Checksum is stored
    checksum_valid becomes 1

Output receiver ready:
    Checksum is transferred
    Buffer becomes available

Output receiver stalled:
    Checksum remains stored
    checksum_valid remains 1
    checksum_data remains stable
    Input backpressure is applied
```

A conventional skid buffer normally contains one or more temporary registers between two ready/valid interfaces. It is used to capture a transaction when the downstream interface is unable to accept it immediately.

A typical skid buffer contains:

- Input `valid`, `ready`, and data signals
- Output `valid`, `ready`, and data signals
- A storage register
- A valid bit indicating whether the storage register is occupied
- Logic that allows pass-through when the downstream is ready
- Logic that captures data when the downstream stalls

For this checksum calculator, the current output register provides the required storage for one completed checksum. Therefore, it performs the essential buffering and stability function required for the output interface, but it is not implemented as a reusable standalone skid-buffer module.

## Buffer Capacity Limitation

The current design can hold only one completed checksum.

If the checksum receiver stalls after a packet completes:

- The current checksum is retained.
- The input eventually becomes not ready.
- Additional packets cannot be accepted until the pending checksum is transferred.

This is safe because no checksum is lost, but it limits throughput during long output stalls.

To support multiple completed packets during output backpressure, the design would need a checksum FIFO.

A FIFO-based implementation would provide:

- Multiple checksum storage entries
- Continued packet acceptance while the FIFO has space
- Backpressure only when the FIFO becomes full
- Better decoupling between packet input and checksum output

However, no finite FIFO can absorb an unlimited number of packets if the downstream receiver stalls indefinitely. Once the FIFO becomes full, backpressure must propagate to the input interface.

## Verification Testbench

The testbench is implemented in [`tb.v`](./tb.v).

It includes:

- Input driver tasks
- Random input gaps
- Random packet generation
- Output backpressure generation
- Reference checksum calculation
- Expected checksum queue
- Output scoreboard
- Protocol checks
- Coverage counters
- Timeout protection
- Directed and randomized test sequences

## Reference Model

The testbench maintains an independent checksum model.

For every accepted input byte:

1. The byte is added to the reference accumulator.
2. The result is truncated to eight bits.
3. The packet length is updated.
4. When `s_axis_tlast` is accepted, the expected checksum is pushed into a scoreboard queue.
5. The reference accumulator is cleared for the next packet.

The DUT output is checked against the expected checksum queue whenever:

```verilog
checksum_valid && checksum_ready
```

is true.

## Verification Scenarios

The testbench verifies the following cases:

### Single-Byte Packet

A packet containing one byte produces that same byte as its checksum.

```text
Input:    A5
Checksum: A5
```

### Multi-Byte Packet

Multiple packet bytes are accumulated until `s_axis_tlast` is asserted.

```text
Input:    01 02 03 04
Checksum: 0A
```

### Consecutive Packets

Packets can arrive back-to-back without idle cycles between them when the output interface is available.

### Input Gaps

The testbench inserts random gaps by deasserting `s_axis_tvalid` between accepted input bytes.

### Output Backpressure

The testbench randomly deasserts `checksum_ready` to verify that:

- The checksum remains valid.
- The checksum data remains stable.
- No checksum is lost.
- The DUT applies input backpressure when necessary.

### Checksum Overflow

Overflow cases are tested explicitly.

```text
0xFF + 0x01 = 0x100
Checksum     = 0x00
```

### Random Packets

Random packets are generated with:

- Random packet lengths
- Random byte contents
- Random input gaps
- Random output backpressure

## Protocol Checks

The testbench checks that:

- No unknown value appears on important control outputs.
- `checksum_valid` does not drop while the output is stalled.
- `checksum_data` does not change while the output is stalled.
- Every accepted packet produces one checksum.
- No unexpected checksum is produced.
- No checksum is missing.
- Every produced checksum matches the reference model.
- The simulation does not hang indefinitely.

## Coverage Counters

The testbench reports counters for:

- Single-byte packets
- Multi-byte packets
- Overflow packets
- Consecutive packets
- Output stall cycles
- Input stall cycles
- Input idle cycles

These counters help confirm that important traffic conditions were exercised.

## Running the Simulation

### Icarus Verilog

Compile the RTL and testbench:

```bash
iverilog -g2012 -o checksum_sim packet_checksum.v tb.v
```

Run the simulation:

```bash
vvp checksum_sim
```

A successful simulation reports:

```text
*** TEST PASSED ***
```

The simulation also prints the number of packets checked and the coverage counters.

## Example Simulation Flow

A typical simulation performs the following sequence:

```text
1. Apply reset
2. Send a single-byte packet
3. Send a multi-byte packet
4. Test checksum overflow
5. Send consecutive random packets
6. Send packets with input gaps
7. Apply random output backpressure
8. Apply a long output stall
9. Run randomized regression packets
10. Drain all pending checksums
11. Report results and coverage
```

## Throughput Considerations

When the output receiver is continuously ready, the design can accept packet bytes on consecutive cycles whenever no completed checksum is blocking the output register.

When the output receiver stalls:

- The completed checksum remains buffered.
- The input interface is backpressured.
- Packet processing pauses until output storage becomes available.

The design prioritizes correctness and lossless ready/valid behavior over unlimited buffering.

## Possible Future Improvements

Possible extensions include:

- Replacing the output register with a configurable checksum FIFO
- Adding a dedicated reusable skid-buffer module
- Adding SystemVerilog assertions
- Adding functional coverage groups
- Adding constrained-random packet classes
- Adding a reference model class
- Adding multiple independent output consumers
- Adding parameterized data width
- Adding configurable checksum algorithms
- Adding support for packet error signals
- Adding formal verification properties
- Adding a separate interface definition for the stream signals

## Skid Buffer Extension

A dedicated skid buffer could be inserted between the packet checksum logic and the checksum output interface.

The structure would be:

```text
Input Stream
     |
     v
Packet Checksum Calculator
     |
     v
Checksum Skid Buffer
     |
     v
Output Stream
```

The skid buffer would contain:

- A data register
- A valid register
- Input ready logic
- Output valid logic
- Output data logic
- Logic to hold data during output stalls

The skid buffer must guarantee:

```text
valid && !ready
```

means that the output data remains stable until a handshake occurs.

For example:

```verilog
if (out_valid && !out_ready) begin
    out_valid <= out_valid;
    out_data  <= out_data;
end
```

The buffer must also correctly support simultaneous output consumption and new input capture. This allows the buffer to maintain throughput when the current output is accepted in the same cycle that a new checksum becomes available.

## Limitations

The current implementation has a single checksum output storage entry.

Therefore:

- It cannot buffer an unlimited number of packet results.
- A permanently stalled receiver eventually stops the input stream.
- Input backpressure is required to prevent data loss.
- A FIFO is required for multiple outstanding checksum results.
- A finite FIFO cannot guarantee unlimited traffic during an indefinite downstream stall.

These limitations are expected for a lossless ready/valid design with finite storage.

## License

This project is licensed under the MIT License. See [`LICENSE`](./LICENSE) for details.
