module alu #(
    parameter INST_W = 4,
    parameter INT_W  = 6,
    parameter FRAC_W = 10,
    parameter DATA_W = INT_W + FRAC_W
)(
    input                      i_clk,
    input                      i_rst_n,

    input                      i_in_valid,
    output                     o_busy,
    input         [INST_W-1:0] i_inst,
    input  signed [DATA_W-1:0] i_data_a,
    input  signed [DATA_W-1:0] i_data_b,

    output                     o_out_valid,
    output        [DATA_W-1:0] o_data
);

    // Local Parameters

    parameter ADD  = 4'b0000;
    parameter SUB  = 4'b0001;
    parameter MUL  = 4'b0010;
    parameter ACC  = 4'b0011;
    parameter SOFTPLUS = 4'b0100;
    parameter XOR_OP = 4'b0101;
    parameter ARITH_SHIFT_RIGHT = 4'b0110;
    parameter LEFT_ROTATE = 4'b0111;
    parameter LEAD_ZERO_COUNT = 4'b1000;
    parameter REV_MATCH4 = 4'b1001;
    integer i;

    // Wires and Regs
    logic signed [31:0] intermediate_result;
    logic signed [31:0] acc [0:15];
    logic signed [15:0] result, reg_result;
    logic [3:0] count;
    logic [3:0] slice_a, slice_b;
    logic out_valid,add_acc;


    // Continuous Assignments
    
    assign o_out_valid = (out_valid) ? 1 : 0;
    assign o_busy = 0;
    assign o_data = (out_valid)? reg_result : 0;

    // Fixed-point multipliers (approximations)
    parameter signed [13:0] MUL_1_DIV_3 = 'sb0101_0101_0101_01;
    //parameter signed [15:0] MUL_1_DIV_3 = 'sb0101_0101_0101_0101;
    parameter signed [13:0] MUL_1_DIV_9 = 'sb0001_1100_0111_00;
    //parameter signed [15:0] MUL_1_DIV_9 = 'sb0001_1100_0111_0001;
    parameter signed [15:0] Shift_2 = 2048;
    parameter signed [15:0] Shift_3 = 3072;
    parameter signed [15:0] Shift_5 = 5120;
    parameter signed [15:0] Shift_n1 = -1024;
    parameter signed [15:0] Shift_n2 = -2048;
    parameter signed [15:0] Shift_n3 = -3072;

    // function
    // Saturation
    function [15:0] saturate;
        input signed [31:0] value;  // 32-bit input to handle overflow
        begin
            if (value > 32767)
                saturate = 16'h7FFF;  // Maximum 16-bit signed value
            else if (value < -32768)
                saturate = 16'h8000;  // Minimum 16-bit signed value
            else
                saturate = value[15:0];  // If no overflow, return 16-bit result
        end
    endfunction

    // Shift and Round
    function [15:0] round_and_saturate;
        input signed [31:0] value;
        logic signed [31:0] temp; 
        begin
            if (value[9] == 1) begin
                temp = (value + 1024) >>> 10;
            end else begin
                temp = value >>> 10;
            end            
            round_and_saturate = saturate(temp);
        end
    endfunction

    // Shift and Round2
    function [15:0] round_and_saturate2;
        input signed [31:0] value;
        logic signed [31:0] temp; 
        begin
            if (value[13] == 1) begin
                temp = (value + 16384) >>> 14;
            end else begin
                temp = value >>> 14;
            end            
            round_and_saturate2 = saturate(temp);
        end
    endfunction


    function [15:0] softplus;
        input signed [15:0] value;
            
        if(value >= Shift_2) begin
            softplus = value;
        end
        else if(value <= Shift_n3) begin
            softplus = 0;
        end
        else if(value <= Shift_2 && value >= 0) begin
            intermediate_result = ( value * 2 + Shift_2 ) * MUL_1_DIV_3;
            softplus = round_and_saturate2(intermediate_result);
        end
        else if(value <= 0 && value >= Shift_n1) begin
            intermediate_result = (value + Shift_2 ) * MUL_1_DIV_3;
            softplus = round_and_saturate2(intermediate_result);
        end
        else if(value <= Shift_n1 && value >= Shift_n2) begin
            intermediate_result = (value * 2  + Shift_5 ) * MUL_1_DIV_9;
            softplus = round_and_saturate2(intermediate_result);
        end
        else if(value <= Shift_n2 && value >= Shift_n3) begin
            intermediate_result = (value + Shift_3 ) * MUL_1_DIV_9;
            softplus = round_and_saturate2(intermediate_result);
        end        
    endfunction


        // Combinatorial Blocks
    always @(*) begin
        // Default values
        intermediate_result = 32'd0;    
        result = 16'd0;
        add_acc = 0;
        case (i_inst)
            ADD: begin
                // Signed Addition
                intermediate_result = i_data_a + i_data_b;
                result = saturate(intermediate_result);
            end
            SUB: begin
                // Signed Subtraction
                intermediate_result = i_data_a - i_data_b;
                result = saturate(intermediate_result);
            end
            MUL: begin
                // Signed Multiplication
                intermediate_result = i_data_a * i_data_b;
                result = round_and_saturate(intermediate_result);
            end
            ACC: begin                        
                intermediate_result = acc[i_data_a] + i_data_b;
                result = saturate(intermediate_result);
                add_acc = 1;
            end
            SOFTPLUS: begin            
                result = softplus(i_data_a);
            end
            XOR_OP: begin
                // XOR Operation
                result = i_data_a ^ i_data_b;
            end
            ARITH_SHIFT_RIGHT: begin
                // Arithmetic Right Shift
                result = i_data_a >>> i_data_b;
            end
            LEFT_ROTATE: begin                        
                result = (i_data_a << i_data_b) | (i_data_a >> (16 - i_data_b));            
            end
            LEAD_ZERO_COUNT: begin            
                count = 0;  // Initialize count to 0
                for (i = 15; i >= 0; i = i - 1) begin
                    if (i_data_a[i] == 1'b1) begin
                        count = 15 - i;  // Count the number of leading zeros
                        break;  // Exit the loop once the first '1' is found
                    end
                end
                result = $signed({1'b0,count});
            end
            REV_MATCH4: begin            
                for (i = 0; i <= 12; i = i + 1) begin                
                    slice_a = (i_data_a >> i) & 4'b1111;
                    slice_b = (i_data_b >> (12 - i)) & 4'b1111;                
                    if (slice_a == slice_b) begin
                        result[i] = 1'b1;  // Set o_data[i] to 1 if match
                    end
                end
            end
        endcase
    end



        // Sequential Blocks
    always @(posedge i_clk or negedge i_rst_n) begin        
        if (!i_rst_n ) begin
            reg_result <= 0;
            for (i = 0; i < 16; i+=1) begin
                acc[i] <= 0;
            end    
            out_valid <= 0;
        end
        else if (i_in_valid) begin
            out_valid <= 1;        
            for(i = 0; i < 16; i+=1) begin
                if (add_acc==1 && i == i_data_a) begin
                    acc[i] <= intermediate_result;
                end
                else begin
                    acc[i] <= acc[i];
                end
            end
            reg_result <= result;
        end
        else begin
            out_valid <= 0;
            for(i = 0; i < 16; i+=1) begin
                acc[i] <= acc[i];
            end
            reg_result <= 0;
        end    
    end





endmodule

// vcs -full64 -R -f rtl.f +v2k -sverilog -debug_access+all +define+$1