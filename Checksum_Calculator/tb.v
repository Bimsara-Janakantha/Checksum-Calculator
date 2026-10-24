`timescale 1ns/1ps
module tb;

    // ---------------- DUT signals ----------------
    reg        clk;                       // Clock driven by the TB
    reg        rst_n;                     // Reset driven by the TB

    reg  [7:0] s_axis_tdata;              // Input byte to DUT
    reg        s_axis_tvalid;             // Input valid to DUT
    wire       s_axis_tready;             // Ready from DUT
    reg        s_axis_tlast;              // Last-byte flag to DUT
    
    wire [7:0] checksum_data;             // Checksum byte from DUT
    wire       checksum_valid;            // Checksum valid from DUT
    reg        checksum_ready;            // Receiver ready, driven by TB backpressure generator

    packet_checksum dut (                 // Instantiate the design under test
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .checksum_data(checksum_data), .checksum_valid(checksum_valid),
        .checksum_ready(checksum_ready)
    );

    // ---------------- Clock ----------------
    initial clk = 1'b0;                   // Start clock low
    always #5 clk = ~clk;                 // Toggle every 5 ns -> 10 ns period (100 MHz)

    // ---------------- Scoreboard storage ----------------
    reg [7:0] exp_q [0:4095];             // Queue of expected checksums (circular, 4096 deep)
    integer   wr_ptr;                     // Total expected checksums pushed (input monitor)
    integer   rd_ptr;                     // Total checksums popped/compared (output monitor)
    integer   errors;                     // Error counter, test passes only if 0

    // ---------------- Reference model state ----------------
    reg [7:0] exp_acc;                    // Reference running sum for current packet
    reg [8:0] full;                       // 9-bit sum so carry-out is visible (for coverage)
    reg       pkt_ovf;                    // Set if carry occurred inside current packet
    integer   pkt_len;                    // Bytes accepted so far in current packet
    reg       prev_last_fire;             // Last cycle accepted a tlast byte (for b2b coverage)

    // ---------------- Coverage counters ----------------
    integer cov_single;                   // Single-byte packets seen
    integer cov_multi;                    // Multi-byte packets seen
    integer cov_ovf;                      // Packets whose sum overflowed 8 bits
    integer cov_b2b;                      // New packet's first byte accepted right after previous packet's last
    integer cov_out_stall;                // Cycles with checksum_valid && !checksum_ready
    integer cov_in_stall;                 // Cycles with tvalid && !tready
    integer cov_in_idle;                  // Cycles with tvalid low (source gaps)

    // ---------------- Input monitor + reference model ----------------
    always @(posedge clk) begin           // Sample at every rising edge (pre-NBA values)
        if (rst_n) begin                  // Only after reset release
            // Count input stalls
            if (s_axis_tvalid && !s_axis_tready) 
                cov_in_stall = cov_in_stall + 1;

            // Count source gaps
            if (!s_axis_tvalid)                  
                cov_in_idle  = cov_in_idle  + 1; 
            
            // A byte is accepted
            if (s_axis_tvalid && s_axis_tready) begin                              
                
                // Immediately follows a packet end
                if (prev_last_fire && pkt_len == 0) 
                    cov_b2b = cov_b2b + 1;         
                
                // 9-bit add to see carry
                full    = {1'b0, exp_acc} + {1'b0, s_axis_tdata};  
                if (full[8]) pkt_ovf = 1'b1;     // Remember overflow happened
                exp_acc = full[7:0];             // Keep low 8 bits (mod 256)
                pkt_len = pkt_len + 1;           // One more byte in this packet

                // End of packet
                if (s_axis_tlast) begin                            
                    // Push the expected checksum into the scoreboard queue
                    exp_q[wr_ptr % 4096] = exp_acc;  // Push expected checksum
                    wr_ptr = wr_ptr + 1;             // Advance write pointer

                    // Update coverage counters
                    if (pkt_len == 1) cov_single = cov_single + 1; // Cover single-byte packet
                    else              cov_multi  = cov_multi  + 1; // Cover multi-byte packet
                    if (pkt_ovf)      cov_ovf    = cov_ovf    + 1; // Cover overflow packet

                    // Reset reference model for next packet
                    exp_acc = 8'd0;           // Reset model for next packet
                    pkt_ovf = 1'b0;           // Clear overflow flag
                    pkt_len = 0;              // Clear length counter
                    prev_last_fire = 1'b1;    // Remember: last byte just fired
                end 
                
                // Not a last byte
                else begin
                    prev_last_fire = 1'b0;                         
                end
            end 
            
            // No accept this cycle -> not back-to-back
            else begin
                prev_last_fire = 1'b0;                             
            end
        end
    end

    // ---------------- Output monitor + checker ----------------
    always @(posedge clk) begin           // Sample at every rising edge
        if (rst_n) begin
            // Count output stalls
            if (checksum_valid && !checksum_ready) 
                cov_out_stall = cov_out_stall + 1; 
            
            // Valid but nothing expected
            if (checksum_valid && (rd_ptr == wr_ptr)) begin        
                errors = errors + 1;
                $display("ERROR @%0t: checksum_valid asserted with no expected checksum", $time);
            end

            // Output handshake
            if (checksum_valid && checksum_ready && (rd_ptr != wr_ptr)) begin
                // Checksum mismatch
                if (checksum_data !== exp_q[rd_ptr % 4096]) begin
                    errors = errors + 1;
                    $display("ERROR @%0t: checksum mismatch got=%h exp=%h (pkt #%0d)",
                             $time, checksum_data, exp_q[rd_ptr % 4096], rd_ptr);
                end

                // Consume the expected entry
                rd_ptr = rd_ptr + 1;                               
            end
        end
    end

    // ---------------- Protocol checker (output stability, X checks) ----------------
    reg       prev_stall;                 // Previous cycle: valid && !ready
    reg [7:0] prev_data;                  // Previous cycle's checksum_data

    always @(posedge clk) begin
        // No stall history during reset
        if (!rst_n) begin
            prev_stall = 1'b0;            
        end 
        
        // Check for X on control outputs and stability during stalls
        else begin
            // Check for X on control outputs
            if (checksum_valid === 1'bx || s_axis_tready === 1'bx) begin  
                errors = errors + 1;
                $display("ERROR @%0t: X on checksum_valid or s_axis_tready", $time);
            end

            // Last cycle we were stalled:
            if (prev_stall) begin                                  
                // valid must NOT drop
                if (checksum_valid !== 1'b1) begin                 
                    errors = errors + 1;
                    $display("ERROR @%0t: checksum_valid dropped before handshake", $time);
                end

                // data must NOT change
                if (checksum_data !== prev_data) begin 
                    errors = errors + 1;
                    $display("ERROR @%0t: checksum_data changed while stalled", $time);
                end
            end

            // Remember for next cycle
            prev_stall = checksum_valid && !checksum_ready; 
            prev_data  = checksum_data;  
        end
    end

    // ---------------- Output backpressure generator ----------------
    integer bp_mode;                      // 0: always ready, 1: random 50%, 2: mostly stalled, 3: fully stalled
    always @(posedge clk) begin
        case (bp_mode)
            0:       checksum_ready <= 1'b1;                       // Receiver always ready
            1:       checksum_ready <= $random;                    // LSB of $random -> 50% ready
            2:       checksum_ready <= (({$random} % 8) == 0);     // ready ~1 cycle in 8 (long stalls)
            default: checksum_ready <= 1'b0;                       // Receiver never ready
        endcase
    end

    // ---------------- Driver tasks ----------------
    // Send one byte, hold it until accepted, then optionally insert a random gap.
    task send_byte;
        input [7:0]   d;           // Byte to send
        input         last;        // tlast value
        input integer gap_max;     // Max random idle cycles after this byte (0 = none)
        integer g;                 // Chosen gap length
        
        begin
            s_axis_tdata  <= d;    // Present data
            s_axis_tlast  <= last; // Present tlast
            s_axis_tvalid <= 1'b1; // Present valid

            // Wait for the edge at which DUT samples us
            @(posedge clk);               

            // Not accepted: keep everything stable and wait    
            while (s_axis_tready !== 1'b1)
                @(posedge clk);
            
            // Accepted at that edge. Now maybe insert a gap.
            if (gap_max > 0) begin
                g = {$random} % (gap_max + 1);   // Random gap 0..gap_max
                if (g > 0) begin
                    s_axis_tvalid <= 1'b0;       // Drop valid for the gap
                    repeat (g) @(posedge clk);   // Wait g cycles
                end
            end
        end
    endtask

    // Send a packet of random bytes.
    task send_random_packet;
        input integer len;      // Packet length in bytes (>= 1)
        input integer gap_max;  // Gap setting passed to send_byte
        integer k;              // Byte index
        reg [7:0] d;            // Random data byte

        begin
            for (k = 0; k < len; k = k + 1) begin
                d = $random;                              // Random byte (low 8 bits)
                send_byte(d, (k == len-1), gap_max);      // tlast on final byte only
            end
        end
    endtask

    // Wait until all expected checksums are received, then check for extras.
    task drain;
        integer t;                        // Timeout counter

        begin
            s_axis_tvalid <= 1'b0;        // No more input
            bp_mode = 0;                  // Receiver always ready so everything flushes
            t = 0;
            
            // Wait for scoreboard to empty
            while ((rd_ptr != wr_ptr) && (t < 2000)) begin   
                @(posedge clk);
                t = t + 1;
            end

            // Timed out -> checksum(s) lost
            if (rd_ptr != wr_ptr) begin                      
                errors = errors + 1;
                $display("ERROR: drain timeout, %0d checksum(s) missing", wr_ptr - rd_ptr);
            end
            
            // Extra cycles: any spurious checksum would be flagged by the monitor
            repeat (10) @(posedge clk);   
        end
    endtask

    // ---------------- Main test sequence ----------------
    integer i;                            // Loop variable
    initial begin
        // Initialise all TB state
        errors = 0; wr_ptr = 0; rd_ptr = 0;
        exp_acc = 0; pkt_ovf = 0; pkt_len = 0; prev_last_fire = 0;
        cov_single = 0; cov_multi = 0; cov_ovf = 0; cov_b2b = 0;
        cov_out_stall = 0; cov_in_stall = 0; cov_in_idle = 0;
        bp_mode = 0; prev_stall = 0; prev_data = 0;
        rst_n = 1'b0; s_axis_tvalid = 1'b0; s_axis_tdata = 8'd0;
        s_axis_tlast = 1'b0; checksum_ready = 1'b0;

        repeat (5) @(posedge clk);        // Hold reset for 5 cycles
        rst_n <= 1'b1;                    // Release reset
        repeat (2) @(posedge clk);        // Let things settle

        // ---- Test 1: single-byte packet ----
        $display("TEST 1: single-byte packet");
        send_byte(8'hA5, 1'b1, 0);        // One byte, also the last -> expected checksum A5
        drain;

        // ---- Test 2: multi-byte packet ----
        $display("TEST 2: multi-byte packet");
        send_byte(8'd1, 1'b0, 0);         // 1
        send_byte(8'd2, 1'b0, 0);         // +2
        send_byte(8'd3, 1'b0, 0);         // +3
        send_byte(8'd4, 1'b1, 0);         // +4 = 10 (0x0A), last
        drain;

        // ---- Test 3: overflow ----
        $display("TEST 3: overflow");
        send_byte(8'hFF, 1'b0, 0);        // FF
        send_byte(8'h01, 1'b1, 0);        // FF+01 = 100 -> checksum 00
        send_byte(8'hFF, 1'b0, 0);        // Second packet: FF
        send_byte(8'hFF, 1'b0, 0);        // +FF
        send_byte(8'hFF, 1'b1, 0);        // +FF = 2FD -> checksum FD
        drain;

        // ---- Test 4: consecutive packets, no gaps, receiver always ready ----
        $display("TEST 4: Consecutive packets, no gaps");
        bp_mode = 0;
        for (i = 0; i < 20; i = i + 1)
            send_random_packet(1 + ({$random} % 4), 0);   // Lengths 1..4, no gaps
        drain;

        // ---- Test 5: random input gaps ----
        $display("TEST 5: random input gaps");
        bp_mode = 0;
        for (i = 0; i < 30; i = i + 1)
            send_random_packet(1 + ({$random} % 8), 3);   // Lengths 1..8, gaps 0..3 cycles
        drain;

        // ---- Test 6: output backpressure (random + mostly stalled) ----
        $display("TEST 6: random output backpressure");
        bp_mode = 1;
        for (i = 0; i < 30; i = i + 1)
            send_random_packet(1 + ({$random} % 6), 0);
        
        bp_mode = 2;
        for (i = 0; i < 20; i = i + 1)
            send_random_packet(1 + ({$random} % 6), 0);
        drain;

        // ---- Test 7: long full stall, then release ----
        $display("TEST 7: 40-cycle full stall");
        bp_mode = 3;                      // Receiver stalls completely
        fork
            // Thread A: push 3 packets; stalls after the first checksum
            begin                         
                send_random_packet(4, 0);
                send_random_packet(3, 0);
                send_random_packet(1, 0);
            end

            // Thread B: release the stall after 40 cycles
            begin                         
                repeat (40) @(posedge clk);
                bp_mode = 0;
            end
        join
        drain;

        // ---- Test 8: random regression ----
        $display("TEST 8: random regression (500 packets)");
        for (i = 0; i < 500; i = i + 1) begin
            if ((i % 20) == 0) bp_mode = {$random} % 3;       // Change backpressure mode every 20 packets
            send_random_packet(1 + ({$random} % 16), {$random} % 4);  // Length 1..16, gap_max 0..3
        end
        drain;

        // ---- Final report ----
        $display("-------------------------------------------");
        $display("Packets checked      : %0d", rd_ptr);
        $display("Coverage: single=%0d multi=%0d overflow=%0d b2b=%0d",
                 cov_single, cov_multi, cov_ovf, cov_b2b);
        $display("Coverage: out_stall_cycles=%0d in_stall_cycles=%0d in_idle_cycles=%0d",
                 cov_out_stall, cov_in_stall, cov_in_idle);
        
        // Final pass/fail report
        if (errors == 0) 
            $display("*** TEST PASSED ***");
        else
            $display("*** TEST FAILED: %0d error(s) ***", errors);
        
        // End simulation
        $finish;                                              
    end

    // ---------------- Watchdog ----------------
    initial begin
        #20_000_000;                                          // 20 ms of simulated time
        $display("*** TIMEOUT: simulation hung ***");
        $finish;
    end

endmodule
