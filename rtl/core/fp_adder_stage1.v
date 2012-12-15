// 
// Copyright 2011-2012 Jeff Bush
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// 

`include "instruction_format.h"

// 
// Stage 1 of the floating point addition pipeline
// - Compute the amount to shift the exponents to align the significands
// - Swap significands if needed so the smaller one is in the second slot
// - Convert the significands to twos complement
// - Detect if the result is inf or nan
//

module fp_adder_stage1
	#(parameter EXPONENT_WIDTH = 8, 
	parameter SIGNIFICAND_WIDTH = 23,
	parameter TOTAL_WIDTH = 1 + EXPONENT_WIDTH + SIGNIFICAND_WIDTH)

	(input								clk,
	input								reset_n,
	input [5:0]							operation_i,
	input [TOTAL_WIDTH - 1:0]			operand1,
	input [TOTAL_WIDTH - 1:0]			operand2,
	output reg[5:0] 					add1_operand_align_shift,
	output reg[SIGNIFICAND_WIDTH + 2:0] add1_significand1,
	output reg[EXPONENT_WIDTH - 1:0] 	add1_exponent1,
	output reg[SIGNIFICAND_WIDTH + 2:0] add1_significand2,
	output reg[EXPONENT_WIDTH - 1:0] 	add1_exponent2,
	output reg 							add1_result_is_inf,
	output reg 							add1_result_is_nan,
	output reg 							add1_exponent2_larger);

	reg[SIGNIFICAND_WIDTH + 2:0] 		swapped_significand1_nxt;
	reg[SIGNIFICAND_WIDTH + 2:0] 		swapped_significand2_nxt;
	reg 								result_is_inf_nxt;
	reg 								result_is_nan_nxt;
	reg[5:0] 							operand_align_shift_nxt;
	reg[SIGNIFICAND_WIDTH + 2:0] 		twos_complement_significand1;
	reg[SIGNIFICAND_WIDTH + 2:0] 		twos_complement_significand2;
	reg 								is_nan1;
	reg 								is_inf1;
	reg 								is_nan2;
	reg 								is_inf2;

	wire sign1 = operand1[EXPONENT_WIDTH + SIGNIFICAND_WIDTH];
	wire[EXPONENT_WIDTH - 1:0] exponent1 = operand1[EXPONENT_WIDTH + SIGNIFICAND_WIDTH - 1:SIGNIFICAND_WIDTH];
	wire[SIGNIFICAND_WIDTH - 1:0] significand1 = operand1[SIGNIFICAND_WIDTH - 1:0];
	wire sign2 = operand2[EXPONENT_WIDTH + SIGNIFICAND_WIDTH];
	wire[EXPONENT_WIDTH - 1:0] exponent2 = operand2[EXPONENT_WIDTH + SIGNIFICAND_WIDTH - 1:SIGNIFICAND_WIDTH];
	wire[SIGNIFICAND_WIDTH - 1:0] significand2 = operand2[SIGNIFICAND_WIDTH - 1:0];

	// Compute exponent difference
	wire[EXPONENT_WIDTH:0] exponent_difference = exponent1 - exponent2; // Note extra carry bit
	wire exponent2_larger = exponent_difference[EXPONENT_WIDTH];

	// Take absolute value of the exponent difference to compute the shift amount
	always @*
	begin
		if (exponent2_larger)
			operand_align_shift_nxt = ~exponent_difference + 1;
		else
			operand_align_shift_nxt = exponent_difference;
	end

	// Handling for subnormal numbers
	wire hidden_bit1 = exponent1 != 0;
	wire hidden_bit2 = exponent2 != 0;
	
	wire addition = operation_i == `OP_FADD;

	// Convert significands to 2s complement
	always @*
	begin
		if (sign1)
			twos_complement_significand1 = ~{ 2'b00, hidden_bit1, significand1 } + 1;
		else
			twos_complement_significand1 = { 2'b00, hidden_bit1, significand1 };

		if (sign2 ^ !addition)
			twos_complement_significand2 = ~{ 2'b00, hidden_bit2, significand2 } + 1;
		else
			twos_complement_significand2 = { 2'b00, hidden_bit2, significand2 };
	end

	// Swap
	always @*
	begin
		if (exponent2_larger)
		begin
			swapped_significand1_nxt = twos_complement_significand2;
			swapped_significand2_nxt = twos_complement_significand1;
		end
		else
		begin
			swapped_significand1_nxt = twos_complement_significand1;
			swapped_significand2_nxt = twos_complement_significand2;
		end
	end

	// Determine if any of the operands are inf or nan
	always @*
	begin
		if (exponent1 == {EXPONENT_WIDTH{1'b1}})
		begin
			is_inf1 = significand1 == 0;
			is_nan1 = ~is_inf1;
		end
		else
		begin
			is_inf1 = 0;
			is_nan1 = 0;
		end

		if (exponent2 == {EXPONENT_WIDTH{1'b1}})
		begin
			is_inf2 = significand2 == 0;
			is_nan2 = ~is_inf2;
		end
		else
		begin
			is_inf2 = 0;
			is_nan2 = 0;
		end
	end

	always @*
	begin
		if (is_inf1 || is_inf2)
		begin
			if (sign1 != (sign2 ^ !addition) && is_inf1 && is_inf2)
			begin
				// inf - inf = nan
				result_is_nan_nxt = 1;
				result_is_inf_nxt = 0;
			end
			else			
			begin
				// inf +/- anything = inf
				result_is_nan_nxt = 0;
				result_is_inf_nxt = 1;
			end
		end
		else if (is_nan1 || is_nan2)
		begin
			// nan +/- anything = nan
			result_is_nan_nxt = 1;
			result_is_inf_nxt = 0;
		end
		else
		begin
			result_is_nan_nxt = 0;
			result_is_inf_nxt = 0;
		end
	end

	always @(posedge clk, negedge reset_n)
	begin
		if (!reset_n)
		begin
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			add1_exponent1 <= {EXPONENT_WIDTH{1'b0}};
			add1_exponent2 <= {EXPONENT_WIDTH{1'b0}};
			add1_exponent2_larger <= 1'h0;
			add1_operand_align_shift <= 6'h0;
			add1_result_is_inf <= 1'h0;
			add1_result_is_nan <= 1'h0;
			add1_significand1 <= {(1+(SIGNIFICAND_WIDTH+2)){1'b0}};
			add1_significand2 <= {(1+(SIGNIFICAND_WIDTH+2)){1'b0}};
			// End of automatics
		end
		else
		begin
			add1_operand_align_shift 		<= #1 operand_align_shift_nxt;
			add1_significand1 				<= #1 swapped_significand1_nxt;
			add1_significand2 				<= #1 swapped_significand2_nxt;
			add1_exponent1 				<= #1 exponent1;
			add1_exponent2 				<= #1 exponent2;
			add1_result_is_inf 			<= #1 result_is_inf_nxt;
			add1_result_is_nan 			<= #1 result_is_nan_nxt;
			add1_exponent2_larger 			<= #1 exponent2_larger;
		end
	end	
endmodule