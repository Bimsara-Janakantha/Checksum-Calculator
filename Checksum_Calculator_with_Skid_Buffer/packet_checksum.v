`timescale 1ns/1ps

module packet_checksum (
    input  wire       clk,
    input  wire       rst_n,

    // Packet input
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    output wire       s_axis_tready,
    input  wire       s_axis_tlast,

    // Checksum output
    output wire [7:0] checksum_data,
    output wire       checksum_valid,
    input  wire       checksum_ready
);
    // Local paramters
    localparam width = 9;

    // Internal signals
    wire [width-1:0]    sk_data;
    wire                sk_valid;
    wire                sk_ready;

    // Instantiate the skid buffer
    skid_buffer #(width) u_skid (
        .clk    (clk),
        .rst_n  (rst_n),

        .s_data ({s_axis_tlast, s_axis_tdata}),
        .s_valid(s_axis_tvalid),
        .s_ready(s_axis_tready),

        .m_data (sk_data), 
        .m_valid(sk_valid),
        .m_ready(sk_ready) 
    );

    // Instantiate the packet checksum core
    core u_core ( 
        .clk           (clk),
        .rst_n         (rst_n),

        .s_axis_tdata  (sk_data[7:0]),
        .s_axis_tvalid (sk_valid),
        .s_axis_tready (sk_ready),
        .s_axis_tlast  (sk_data[8]),

        .checksum_data (checksum_data),
        .checksum_valid(checksum_valid),
        .checksum_ready(checksum_ready)
    );

endmodule