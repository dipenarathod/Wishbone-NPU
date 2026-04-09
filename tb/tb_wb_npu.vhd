Library ieee;
Use ieee.std_logic_1164.All;
Use ieee.numeric_std.All;

Library work;
Use work.tensor_operations_base.All;
Use work.tensor_operations_pooling.All;
Use work.tensor_operations_activation.All;
Use work.tensor_operations_conv_dense.All;

Entity tb_wb_npu Is
End Entity;

Architecture sim Of tb_wb_npu Is
	Constant CLK_PERIOD                                   : Time                           := 13888 ps;    --1/72MHz = 13888 ps

	Constant BASE_ADDRESS                                 : UNSIGNED(31 Downto 0)          := x"90000000"; --peripheral base (informational)
	Constant TENSOR_A_BASE                                : UNSIGNED(31 Downto 0)          := x"90000600"; --A window base
	Constant TENSOR_B_BASE                                : UNSIGNED(31 Downto 0)          := x"90002D10"; --B window base
	Constant TENSOR_C_BASE                                : UNSIGNED(31 Downto 0)          := x"9000B9B0"; --C window base
	Constant TENSOR_R_BASE                                : UNSIGNED(31 Downto 0)          := x"9000D8F0"; --R window base
	Constant CTRL_REG_ADDRESS                             : UNSIGNED(31 Downto 0)          := x"90000008"; --[0]=start, [5:1]=opcode
	Constant STATUS_REG_ADDRESS                           : UNSIGNED(31 Downto 0)          := x"9000000C"; --[0]=busy, [1]=done (sticky)
	Constant DIM_REG_ADDRESS                              : UNSIGNED(31 Downto 0)          := x"90000010"; --N (LSB 8 bits). Conv: input feature width
	Constant POOL_BASE_INDEX_ADDRESS                      : UNSIGNED(31 Downto 0)          := x"90000014"; --top-left index in A
	Constant R_OUT_INDEX_ADDRESS                          : UNSIGNED(31 Downto 0)          := x"90000018"; --out index in R
	Constant WORD_INDEX_ADDRESS                           : UNSIGNED(31 Downto 0)          := x"9000001C"; --word index for tensor indexing
	Constant SUM_REG_ADDRESS                              : UNSIGNED(31 Downto 0)          := x"90000020"; --Softmax sum parameter (write-only)
	Constant SOFTMAX_MODE_ADDRESS                         : UNSIGNED(31 Downto 0)          := x"90000024"; --Softmax mode: 0=EXP, 1=DIV
	Constant WEIGHT_BASE_INDEX_ADDRESS                    : UNSIGNED(31 Downto 0)          := x"90000028"; --Dense: weight base index in B
	Constant BIAS_INDEX_ADDRESS                           : UNSIGNED(31 Downto 0)          := x"9000002C"; --Dense: bias word index in C
	Constant N_INPUTS_ADDRESS                             : UNSIGNED(31 Downto 0)          := x"90000030"; --Dense: number of inputs N. Conv: Number of input channels
	Constant ZERO_POINT_REG_ADDRESS                       : UNSIGNED(31 Downto 0)          := x"9000003C"; --Zero-point register
	Constant QUANTIZED_MULTIPLIER_REG_ADDRESS             : UNSIGNED(31 Downto 0)          := x"90000040"; --Quantized multiplier
	Constant QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS : UNSIGNED(31 Downto 0)          := x"90000044"; --Right shift for Quantized multiplier
	Constant N_OUTPUTS_ADDRESS                            : UNSIGNED(31 Downto 0)          := x"90000048"; --Dense: Nuimber of output neurons. Conv: Number of output channels
	Constant WORDS_TO_COPY_FROM_R_TO_A_ADDRESS            : UNSIGNED(31 Downto 0)          := x"9000004C"; --total words to copy from R to A
	Constant REQUANT_PROD_HI_ADDRESS                      : UNSIGNED(31 Downto 0)          := x"90000050"; --total words to copy from R to A
	Constant REQUANT_PROD_LO_ADDRESS                      : UNSIGNED(31 Downto 0)          := x"90000054"; --total words to copy from R to A
	Constant REQUANT_RESULT_32_ADDRESS                    : UNSIGNED(31 Downto 0)          := x"9000005C"; --total words to copy from R to A
	Constant REQUANT_RESULT_8_ADDRESS                     : UNSIGNED(31 Downto 0)          := x"90000060"; --total words to copy from R to A
	Constant ACCUMULATOR_ADDRESS                          : UNSIGNED(31 Downto 0)          := x"90000064"; --total words to copy from R to A

	--Copied interface from wb_peripheral
	Signal clk                                            : Std_ulogic                     := '0';--system clock
	Signal reset                                          : Std_ulogic                     := '1';--synchronous reset
	Signal i_wb_cyc                                       : Std_ulogic                     := '0';--Wishbone: cycle valid
	Signal i_wb_stb                                       : Std_ulogic                     := '0';--Wishbone: strobe
	Signal i_wb_we                                        : Std_ulogic                     := '0';--Wishbone: 1=write, 0=read
	Signal i_wb_addr                                      : Std_ulogic_vector(31 Downto 0) := (Others => '0');--Wishbone: address
	Signal i_wb_data                                      : Std_ulogic_vector(31 Downto 0) := (Others => '0');--Wishbone: write data
	Signal o_wb_ack                                       : Std_ulogic;--Wishbone: acknowledge
	Signal o_wb_stall                                     : Std_ulogic;--Wishbone: stall (always '0')
	Signal o_wb_data                                      : Std_ulogic_vector(31 Downto 0);--Wishbone: read data

	--Cycle counter (what this test bench is being written for)
	Signal cycle_cnt                                      : Natural := 0;

	--Worst-case
	Constant POOL_TENSOR_SIDE_LEN                         : Natural := 100;
	Constant DENSE_INPUTS                                 : Natural := 18;
	Constant DENSE_NEURONS                                : Natural := 2000;
	Constant CONV_TENSOR_SIDE_LEN                         : Natural := 13;
	Constant CONV_Input_Channels                          : Natural := 50;
	Constant CONV_Output_Channels                         : Natural := 80;
Begin
	--72MHz clock
	clk   <= Not clk After CLK_PERIOD / 2;
	reset <= '1', '0' After CLK_PERIOD / 2;
	--Cycle counter (the most important funciton)
	Process (clk)
	Begin
		If rising_edge(clk) Then
			If reset = '1' Then
				cycle_cnt <= 0;
			Else
				cycle_cnt <= cycle_cnt + 1;
			End If;
		End If;
	End Process;

	dut : Entity work.wb_npu
		Port Map(
			clk        => clk,
			reset      => reset,
			i_wb_cyc   => i_wb_cyc,
			i_wb_stb   => i_wb_stb,
			i_wb_we    => i_wb_we,
			i_wb_addr  => i_wb_addr,
			i_wb_data  => i_wb_data,
			o_wb_ack   => o_wb_ack,
			o_wb_stall => o_wb_stall,
			o_wb_data  => o_wb_data
		);
	stimulus : Process
		Variable status      : Std_ulogic_vector(31 Downto 0);
		Variable ctrl_word   : Std_ulogic_vector(31 Downto 0);
		Variable start_cyc   : Natural;
		Variable done_cyc    : Natural;
		Variable result_word : Std_ulogic_vector(31 Downto 0);
		--Wishbone write
		Procedure wb_write(
			addr : In unsigned(31 Downto 0);
			data : In Std_ulogic_vector(31 Downto 0)
		) Is
		Begin
			i_wb_addr <= Std_ulogic_vector(addr);
			i_wb_data <= data;
			i_wb_we   <= '1'; --Write
			i_wb_cyc  <= '1'; --Valid cycle
			i_wb_stb  <= '1'; --Peripheral selected

			--wait for peripheral to assert termination of a valid clock cycle
			Wait Until rising_edge(clk);
			While o_wb_ack = '0' Loop
				Wait Until rising_edge(clk);
			End Loop;

			i_wb_cyc <= '0'; --Cycle over
			i_wb_stb <= '0';-- peripheral not selected
			i_wb_we  <= '0';--Not writing
		End Procedure;

		--Wishbone read
		Procedure wb_read(
			addr : In  unsigned(31 Downto 0);
			data : Out Std_ulogic_vector(31 Downto 0)
		) Is
		Begin
			i_wb_addr <= Std_ulogic_vector(addr);
			i_wb_we   <= '0'; --Reading
			i_wb_cyc  <= '1'; --Valid cycle
			i_wb_stb  <= '1'; --Peripheral selected

			--wait for peripheral to assert termination of a valid clock cycle
			Wait Until rising_edge(clk);
			While o_wb_ack = '0' Loop
				Wait Until rising_edge(clk);
			End Loop;

			data := o_wb_data;
			i_wb_cyc <= '0'; --Cycle over
			i_wb_stb <= '0';-- peripheral not selected
		End Procedure;

		Procedure start_and_time(
			op_name : In String;
			op_code : In Std_ulogic_vector(4 Downto 0)
		) Is
		Begin
			--Ensure previous command is fully cleared
			wb_write(CTRL_REG_ADDRESS, (Others => '0'));
			Wait Until rising_edge(clk);
			Wait Until rising_edge(clk);
			--Wqait until ctrl reg is fully cleared
			Loop
				wb_read(CTRL_REG_ADDRESS, result_word);
				Exit When result_word = x"00000000";
			End Loop;

			ctrl_word             := (Others => '0'); --Empty the ctrl word that needs to be written to the NPU
			ctrl_word(5 Downto 1) := op_code;         --load the op code
			ctrl_word(0)          := '1';             --Set the start bit

			wb_write(CTRL_REG_ADDRESS, ctrl_word);    --Write the control command
			--Wait until command is accepted
			Loop
				wb_read(STATUS_REG_ADDRESS, status);
				Exit When status(0) = '1'; --status[0] = busy = 1
			End Loop;
			start_cyc := cycle_cnt; --start counting cycles as soon as the busy bit is set

			--Wait until command is done
			Loop
				wb_read(STATUS_REG_ADDRESS, status);
				Exit When (status(0) = '0' And status(1) = '1'); --status[1] = done = 1 and the busy bit is cleared
			End Loop;

			done_cyc := cycle_cnt;

			Report op_name & " latency (cycles) = " & --Report the cycles used in this operation
				Integer'image(done_cyc - start_cyc)
				Severity note;
		End Procedure;

	Begin
		--Quantization settings (used by Dense and Conv)
		wb_write(ZERO_POINT_REG_ADDRESS, x"00000000");
		wb_write(QUANTIZED_MULTIPLIER_REG_ADDRESS, x"40000000");
		wb_write(QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS, x"00000000");

		--2x2 MaxPool worst case
		wb_write(DIM_REG_ADDRESS, Std_ulogic_vector(to_unsigned(POOL_TENSOR_SIDE_LEN, 32)));
		wb_write(POOL_BASE_INDEX_ADDRESS, x"00000000");
		wb_write(R_OUT_INDEX_ADDRESS, x"00000000");
		start_and_time("MaxPool", OP_MAXPOOL);

		--2x2 AvgPool worst case
		wb_write(DIM_REG_ADDRESS, Std_ulogic_vector(to_unsigned(POOL_TENSOR_SIDE_LEN, 32)));
		wb_write(POOL_BASE_INDEX_ADDRESS, x"00000000");
		wb_write(R_OUT_INDEX_ADDRESS, x"00000000");
		start_and_time("AvgPool", OP_AVGPOOL);

		--ReLU worst-case
		wb_write(WORD_INDEX_ADDRESS, x"00000000");
		wb_write(N_INPUTS_ADDRESS, Std_ulogic_vector(to_unsigned(TENSOR_A_WORDS, 32)));
		start_and_time("ReLU", OP_RELU);

		--Sigmoid worst-case
		wb_write(WORD_INDEX_ADDRESS, x"00000000");
		wb_write(N_INPUTS_ADDRESS, Std_ulogic_vector(to_unsigned(TENSOR_A_WORDS, 32)));
		start_and_time("Sigmoid", OP_SIGMOID);

		--Dense worst-case
		wb_write(WORD_INDEX_ADDRESS, x"00000000");
		wb_write(WEIGHT_BASE_INDEX_ADDRESS, x"00000000");
		wb_write(BIAS_INDEX_ADDRESS, x"00000000");
		wb_write(R_OUT_INDEX_ADDRESS, x"00000000");
		wb_write(N_INPUTS_ADDRESS, Std_ulogic_vector(to_unsigned(DENSE_INPUTS, 32)));
		wb_write(N_OUTPUTS_ADDRESS, Std_ulogic_vector(to_unsigned(DENSE_NEURONS, 32)));
		start_and_time("Dense", OP_DENSE);

		--Conv2D worst-case
		wb_write(DIM_REG_ADDRESS, Std_ulogic_vector(to_unsigned(CONV_TENSOR_SIDE_LEN, 32)));
		wb_write(WORD_INDEX_ADDRESS, x"00000000");
		wb_write(WEIGHT_BASE_INDEX_ADDRESS, x"00000000");
		wb_write(BIAS_INDEX_ADDRESS, x"00000000");
		wb_write(R_OUT_INDEX_ADDRESS, x"00000000");
		wb_write(N_INPUTS_ADDRESS, Std_ulogic_vector(to_unsigned(CONV_Input_Channels, 32)));
		wb_write(N_OUTPUTS_ADDRESS, Std_ulogic_vector(to_unsigned(CONV_Output_Channels, 32)));
		start_and_time("Conv2D", OP_CONV);

		Wait For 100 ns;
		Report "Simulation finished" Severity failure;

	End Process;
End Architecture;
--To run:
-- ghdl -a --std=08 tensor_operations_base.vhd
-- ghdl -a --std=08 tensor_operations_pooling.vhd
-- ghdl -a --std=08 tensor_operations_activation.vhd
-- ghdl -a --std=08 tensor_operations_conv_dense.vhd
-- ghdl -a --std=08 wb_npu.vhd
-- ghdl -a --std=08 tb_wb_npu.vhd

-- ghdl -e --std=08 tb_wb_npu
-- ghdl -r --std=08 tb_wb_npu --wave=tb_wb_npu.ghw
-- gtkwave tb_wb_npu.ghw
