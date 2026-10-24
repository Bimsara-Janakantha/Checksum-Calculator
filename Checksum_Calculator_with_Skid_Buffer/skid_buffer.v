`timescale 1ns/1ps

module skid_buffer #(
    parameter width = 9
) (
    input   wire              clk,
    input   wire              rst_n,

    input   wire [width-1:0]  s_data,
    input   wire              s_valid,
    output  wire              s_ready,

    output  reg [width-1:0]   m_data,
    output  reg               m_valid,
    input   wire              m_ready
);
    // Internal signals
    reg [width-1:0]   skid_data;
    reg               skid_valid;

    // Source ready signal definition
    assign s_ready = !skid_valid;

    // Main Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear output registers
            m_valid     <= 1'b0;
            m_data      <= {width{1'b0}};

            // Clear skid buffer
            skid_valid  <= 1'b0;
            skid_data   <= {width{1'b0}};
        end

        else begin
            // Case 1: Skid buffer is full
            if (skid_valid) begin
                if (m_ready) begin 
                    m_data      <= skid_data;
                    m_valid     <= 1'b1;
                    skid_valid  <= 1'b0;
                end
            end

            // Case 2: Skid buffer is empty
            else begin
                // Case 2.A: Main register is empty or begin emptied (Core is accepting data)
                if(!m_valid || m_ready) begin
                    m_valid <= s_valid;
                    if (s_valid) 
                        m_data  <= s_data;
                end

                // Case 2.B: Src data is valid, main register is full and core is not ready to accept data
                else if(s_valid) begin
                    skid_data   <= s_data;
                    skid_valid  <= 1'b1;
                end

                // Case 2. C: Otherwise, maintain the current state of the main register and skid buffer
            end
        end
        
    end
endmodule