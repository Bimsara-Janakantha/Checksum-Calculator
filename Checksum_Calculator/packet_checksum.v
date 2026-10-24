`timescale 1ns/1ps

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
    // Internal signals
    reg [7:0] accumulator;
    wire [7:0] next_accumulator;

    // Assert/deassert s_axis_tready 
    assign s_axis_tready = !checksum_valid || checksum_ready;

    // Generate next checksum
    assign next_accumulator = accumulator + s_axis_tdata;

    // Main logic
    always @(posedge clk or negedge rst_n) begin
        // Reset logic
        if (!rst_n) begin
            accumulator     <= 8'd0;
            checksum_data   <= 8'd0;
            checksum_valid  <= 1'b0;
        end 
        
        else begin
            // Receiver took the checksum
            if (checksum_valid && checksum_ready) begin
                checksum_valid <= 1'b0;
            end

            // Checksum calculation logic
            if (s_axis_tvalid && s_axis_tready) begin
                // If this is the last byte of the packet, finalize the checksum
                if (s_axis_tlast) begin
                    checksum_data   <= next_accumulator;
                    checksum_valid  <= 1'b1;
                    accumulator     <= 8'd0;
                end

                // If not the last byte, accumulate the checksum
                else begin
                    accumulator     <= next_accumulator;
                end
            end
            
        end
    end

endmodule
