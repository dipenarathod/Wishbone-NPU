Library ieee;
Use ieee.std_logic_1164.All;
Use ieee.numeric_std.All;

Library work;
Use work.tensor_operations_basic_arithmetic.All; --import opcodes/constants and packed int8 add/sub
Use work.tensor_operations_pooling.All; --import pooling opcodes & helpers (read/max/avg)
Use work.tensor_operations_activation.All;
Use work.tensor_operations_dense.All;
--Revised address for tensors B, C, and R to allow addressing for the new 100x100 tensors (2500 words)
Entity wb_peripheral_top Is
	Generic (
		BASE_ADDRESS              : Std_ulogic_vector(31 Downto 0) := x"90000000"; --peripheral base (informational)
		TENSOR_A_BASE             : Std_ulogic_vector(31 Downto 0) := x"90001000"; --A window base
		TENSOR_B_BASE             : Std_ulogic_vector(31 Downto 0) := x"90004000"; --B window base
		TENSOR_C_BASE             : Std_ulogic_vector(31 Downto 0) := x"90007000"; --C window base
		TENSOR_R_BASE             : Std_ulogic_vector(31 Downto 0) := x"9000A000"; --R window base
		CTRL_REG_ADDRESS          : Std_ulogic_vector(31 Downto 0) := x"90000008"; --[0]=start, [5:1]=opcode
		STATUS_REG_ADDRESS        : Std_ulogic_vector(31 Downto 0) := x"9000000C"; --[0]=busy, [1]=done (sticky)
		DIM_REG_ADDRESS           : Std_ulogic_vector(31 Downto 0) := x"90000010"; --N (LSB 8 bits)
		POOL_BASE_INDEX_ADDRESS   : Std_ulogic_vector(31 Downto 0) := x"90000014"; --top-left index in A
		R_OUT_INDEX_ADDRESS       : Std_ulogic_vector(31 Downto 0) := x"90000018"; --out index in R
		WORD_INDEX_ADDRESS        : Std_ulogic_vector(31 Downto 0) := x"9000001C"; --word index for tensor indexing
		SUM_REG_ADDRESS           : Std_ulogic_vector(31 Downto 0) := x"90000020"; --Softmax sum parameter (write-only)
		SOFTMAX_MODE_ADDRESS      : Std_ulogic_vector(31 Downto 0) := x"90000024"; --Softmax mode: 0=EXP, 1=DIV
		WEIGHT_BASE_INDEX_ADDRESS : Std_ulogic_vector(31 Downto 0) := x"90000028"; --Dense: weight base index in B
		BIAS_INDEX_ADDRESS        : Std_ulogic_vector(31 Downto 0) := x"9000002C"; --Dense: bias word index in C
		N_INPUTS_ADDRESS          : Std_ulogic_vector(31 Downto 0) := x"90000030"; --Dense: number of inputs N
		SCALE_REG_ADDRESS         : Std_ulogic_vector(31 Downto 0) := x"90000034"; --Scale register
		ZERO_POINT_REG_ADDRESS    : Std_ulogic_vector(31 Downto 0) := x"9000003C"; --Zero-point register
		QUANTIZED_MULTIPLIER_REG_ADDRESS    : Std_ulogic_vector(31 Downto 0) := x"90000040";  --Quantized multiplier
		QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS    : Std_ulogic_vector(31 Downto 0) := x"90000044"  --Right shift for Quantized multiplier
	);
	Port (
		clk        : In  Std_ulogic; --system clock
		reset      : In  Std_ulogic; --synchronous reset
		i_wb_cyc   : In  Std_ulogic; --Wishbone: cycle valid
		i_wb_stb   : In  Std_ulogic; --Wishbone: strobe
		i_wb_we    : In  Std_ulogic; --Wishbone: 1=write, 0=read
		i_wb_addr  : In  Std_ulogic_vector(31 Downto 0);--Wishbone: address
		i_wb_data  : In  Std_ulogic_vector(31 Downto 0);--Wishbone: write data
		o_wb_ack   : Out Std_ulogic; --Wishbone: acknowledge
		o_wb_stall : Out Std_ulogic; --Wishbone: stall (always '0')
		o_wb_data  : Out Std_ulogic_vector(31 Downto 0) --Wishbone: read data
	);
End Entity;

Architecture rtl Of wb_peripheral_top Is

	Constant OP_NOP : Std_ulogic_vector(4 Downto 0) := "11111";

	--Wishbone
	Signal ack_r : Std_ulogic := '0';
	Signal wb_req : Std_ulogic := '0'; --Variable tp combine checks (Clock is high and the slave (NPU) is selected)

	--Only allow the CPU to access tensor windows when the NPU is idle.
	--The CPU can still poll the NPU to check if it is busy.
	--
	--To make BRAM inference easier, each tensor memory is written/read from a single clocked process
	--and we multiplex the memory port between WB (when idle) and NPU (when busy).
	Signal npu_busy : Std_ulogic := '0';

	--Wishbone read mux selector (latched for the transaction being acknowledged)
	--000: register readback
	--001: tensor_A window
	--010: tensor_B window
	--011: tensor_C window
	--100: tensor_R window
	Signal wb_rsel : Std_ulogic_vector(2 Downto 0) := (Others => '0'); --select signal for tensor mux
	Signal reg_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');

	--Tensors
	Signal tensor_A_mem : tensor_mem_type := (Others => (Others => '0'));
	Signal tensor_B_mem : tensor_mem_type := (Others => (Others => '0'));
	Signal tensor_C_mem : tensor_mem_type := (Others => (Others => '0'));
	Signal tensor_R_mem : tensor_mem_type := (Others => (Others => '0'));

	--BRAM inference hints
	Attribute ram_style : String;
	Attribute syn_ramstyle : String;

	Attribute ram_style Of tensor_A_mem : Signal Is "block";
	Attribute ram_style Of tensor_B_mem : Signal Is "block";
	Attribute ram_style Of tensor_C_mem : Signal Is "block";
	Attribute ram_style Of tensor_R_mem : Signal Is "block";

	Attribute syn_ramstyle Of tensor_A_mem : Signal Is "block_ram";
	Attribute syn_ramstyle Of tensor_B_mem : Signal Is "block_ram";
	Attribute syn_ramstyle Of tensor_C_mem : Signal Is "block_ram";
	Attribute syn_ramstyle Of tensor_R_mem : Signal Is "block_ram";

	--Read data for Wishbone access to tensors (valid when wb_rsel selects them for reading)
	Signal tensor_A_wb_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');
	Signal tensor_B_wb_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');
	Signal tensor_C_wb_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');
	Signal tensor_R_wb_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');

	--NPU-side BRAM ports (synchronous read, 1-cycle latency)
	--16-bit addresses can address 2^16 = 64KB worth of memort. Change width to more depending on needs
	Signal tensor_A_npu_addr : unsigned(15 Downto 0) := (Others => '0');
	Signal tensor_A_npu_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');

	Signal tensor_B_npu_addr : unsigned(15 Downto 0) := (Others => '0');
	Signal tensor_B_npu_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');

	Signal tensor_C_npu_addr : unsigned(15 Downto 0) := (Others => '0');
	Signal tensor_C_npu_rdata : Std_ulogic_vector(31 Downto 0) := (Others => '0');

	--Control and status registers
	Signal ctrl_reg : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --[0]=start, [5:1]=opcode
	Signal status_reg : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --[0]=busy, [1]=done
	Signal dim_side_len_8 : Std_ulogic_vector(7 Downto 0) := (Others => '0'); --N side length
	Signal dim_side_len_bus : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --zero-extended N

	--Pooling address parameters
	Signal pool_base_index : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --A flat index (top-left)
	Signal r_out_index : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --R flat index

	--Elementwise word index
	Signal word_index_reg : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --packed word index

	--Softmax parameters (write-only from Ada)
	Signal sum_param_reg : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --Sum calculated by Ada
	Signal softmax_mode_reg : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --Flag to differ between exponent and div mode. 0=EXP, 1=DIV
	--Using anpther opcode is possible, but I (DAR) don't suggest wasting an opcode

	--Dense layer parameters
	Signal weight_base_index : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --Weight base element index in B
	Signal bias_index : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --Bias element index in C
	Signal n_inputs_reg : Std_ulogic_vector(31 Downto 0) := (Others => '0'); --Number of inputs for dense layer

	--Start edge detection (one-cycle pulse)
	--ctrl0_prev is introduced to ensure a new command is not triggered every cycle (when ctrl is set)
	Signal start_cmd : Std_ulogic := '0';
	Signal ctrl0_prev : Std_ulogic := '0';

	--Muxed write paths for DIM (allowing bus or internal updates)
	--Will be useful when there is a dedicated pooling/conv unit
	Signal bus_dim_we : Std_ulogic := '0';
	Signal bus_dim_data : Std_ulogic_vector(7 Downto 0) := (Others => '0');
	Signal pool_dim_we : Std_ulogic := '0';
	Signal pool_dim_data : Std_ulogic_vector(7 Downto 0) := (Others => '0');

	--Dense layer operation registers
	Signal weight_base_reg : unsigned(15 Downto 0) := (Others => '0'); --weight base element index
	Signal bias_index_reg : unsigned(15 Downto 0) := (Others => '0'); --bias element index
	Signal n_inputs_latched : unsigned(15 Downto 0) := (Others => '0'); --number of inputs
	Signal mac_counter : unsigned(15 Downto 0) := (Others => '0'); --MAC loop counter
	Signal accumulator : signed(31 Downto 0) := (Others => '0'); --32-bit accumulator
	Signal bias_val_reg : signed(31 Downto 0) := (Others => '0'); --bias value
	Signal prod	:	signed(63 downto 0);	--Intermediate product from dense_requantize
	Signal dense_result : signed(7 Downto 0) := (Others => '0'); --final dense result

	--Dense fast path registers (packed 4x int8 per cycle)
	Signal dense_lane_count : unsigned(2 Downto 0) := (Others => '0'); --how many lanes (1 to 4) are valid this step
	--inlcuded so we can extend it to more lanes possibly (for higher speeds)

	--Pooling datapath registers (2x2 window and result)
	Signal num00_reg, num01_reg, num10_reg, num11_reg : signed(7 Downto 0) := (Others => '0');
	Signal r8_reg : signed(7 Downto 0) := (Others => '0');

	--Vector datapath registers for packed word operations
	Signal a_w_reg, r_w_reg : Std_ulogic_vector(31 Downto 0) := (Others => '0');

	Signal read_index : unsigned(1 Downto 0) := (Others => '0');
	Signal read_index_lat : unsigned(1 Downto 0) := (Others => '0'); --latch variant for read_index
	Signal byte_sel_lat : unsigned(1 Downto 0) := (Others => '0'); --latch variant for byte_sel

	--Quantization helper registers
	Signal scale : std_ulogic_vector(31 downto 0) := (Others => '0');
	Signal zero_point : std_ulogic_vector(31 downto 0) := (Others => '0');
	Signal quantized_multiplier : std_ulogic_vector(31 downto 0) := (Others => '0'); --(lhs_scale * rhs_scale / result_scale) from GEMMlowp's equation 5 is a real number. This multiplier register holds the quanztized version of the real multipler
	Signal quantized_multiplier_right_shift : std_ulogic_vector(31 downto 0) := (Others => '0'); --right shifs required to convert quantized multiplier to the real multiplier
	
	Signal scale_lat : signed(31 downto 0) := (Others => '0'); --scale latched
	Signal zero_point_lat : signed(31 downto 0) := (Others => '0'); --zero point value latched
	Signal quantized_multiplier_lat : signed(31 downto 0) := (Others => '0'); --quantized multipier latched
	Signal quantized_multiplier_right_shift_lat : unsigned(7 downto 0) := (Others => '0'); --right shift latched
	
	--Address helper: translate byte address to word offset within a tensor window
	Function get_tensor_offset(addr, base : Std_ulogic_vector(31 Downto 0)) Return Natural Is
		Variable offset : unsigned(31 Downto 0);
	Begin
		offset := unsigned(addr) - unsigned(base); --word + byte offset (relative position of element from base address)
		--return to_integer(offset(11 downto 2));        --just the word offset
		Return to_integer(shift_right(offset, 2)); --Right shift 2 removes they byte offset within a word. We are left with just the word index
	End Function;

	--Unified FSM state encoding
	Type state_t Is (
		S_IDLE, S_CAPTURE, S_OP_CODE_BRANCH,
		--pooling path states (added a new state, request, to make BRAM inference possible)
		S_P_READ_REQ, S_P_READ_WAIT, S_P_READ_CAP, S_P_CALC, S_P_WRITE,
		--Activation path states
		S_ACT_READ_REQ, S_ACT_READ_WAIT, S_ACT_CALC, S_ACT_WRITE,
		--Dense path states
		S_DENSE_INIT, S_DENSE_BIAS_READ, S_DENSE_BIAS_WAIT, S_DENSE_FETCH, S_DENSE_FETCH_WAIT, S_DENSE_MAC, S_DENSE_BIAS_PRODUCT, S_DENSE_BIAS_CLAMP, S_DENSE_WRITE,
		S_DONE
	);
	Signal state : state_t := S_IDLE;

	--Latched operation parameters for the active command
	Signal op_code_reg : Std_ulogic_vector(4 Downto 0) := (Others => '0'); --opcode field
	Signal base_i_reg : unsigned(15 Downto 0) := (Others => '0'); --pooling base index
	Signal out_i_reg : unsigned(15 Downto 0) := (Others => '0'); --output index
	Signal din_reg : unsigned(7 Downto 0) := (Others => '0'); --N (tensor side length)
	Signal word_i_reg : unsigned(15 Downto 0) := (Others => '0'); --packed word index (int8-granular for dense, word-granular for act)
	Signal softmax_mode_latched : Std_ulogic := '0'; --latched softmax mode

Begin

	--Simple, non-stalling slave peripheral
	o_wb_stall <= '0';

	--Zero-extend N for bus readback
	dim_side_len_bus <= (31 Downto 8 => '0') & dim_side_len_8;

	--Expose NPU busy state
	npu_busy <= '1' When state /= S_IDLE Else '0';
	status_reg(0) <= '1' When state /= S_IDLE Else '0';

	--Generate a one-cycle start pulse when start=1 and not busy
	--Only trigger an operation (start_cmd = 1) when ctrl(0) is transitioning to 1 for the first time and status(0) = 0 (not busy)
	Process (clk)
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				start_cmd <= '0';
				ctrl0_prev <= '0';
			Else
				start_cmd <= '0';
				If (npu_busy = '0' And ctrl_reg(0) = '1' And (ctrl0_prev = '0')) Then
					start_cmd <= '1';
				End If;
				ctrl0_prev <= ctrl_reg(0);
			End If;
		End If;
	End Process;

	--DIM (N) register with two write sources: pooling path or bus write
	Process (clk)
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				dim_side_len_8 <= x"32"; --default N=50.
			Else
				If (pool_dim_we = '1') Then
					dim_side_len_8 <= pool_dim_data; --TODO: When there is a dedicated pooling unit with variable window sizes
				Elsif (bus_dim_we = '1') Then
					dim_side_len_8 <= bus_dim_data; --bus write-update
				End If;
			End If;
		End If;
	End Process;

	--Tensor window accesses are only acknowledged when npu_busy=0
	--The CPU can always access control/status registers
	--This change is to allow BRAM usage (inference) for the main four tensors

	wb_req <= i_wb_cyc And i_wb_stb; --Clock is high and the slave (NPU) is selected

	--The acknowledgement process is combined with the tensor multiplex select logic and register reads
	Process (clk)
		Variable is_valid : Std_ulogic;
		Variable is_tensor : Std_ulogic;

	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				ack_r <= '0';
				wb_rsel <= (Others => '0');
				reg_rdata <= (Others => '0');
			Else
				ack_r <= '0';

				If (wb_req = '1') Then
					--Default
					is_valid := '0';
					is_tensor := '0';
					wb_rsel <= (Others => '0');
					reg_rdata <= (Others => '0');

					--Register reads
					If (i_wb_addr = CTRL_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= ctrl_reg;
					Elsif (i_wb_addr = STATUS_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= status_reg;
					Elsif (i_wb_addr = DIM_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= dim_side_len_bus;
					Elsif (i_wb_addr = POOL_BASE_INDEX_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= pool_base_index;
					Elsif (i_wb_addr = R_OUT_INDEX_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= r_out_index;
					Elsif (i_wb_addr = WORD_INDEX_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= word_index_reg;
					Elsif (i_wb_addr = SOFTMAX_MODE_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= softmax_mode_reg;
					Elsif (i_wb_addr = WEIGHT_BASE_INDEX_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= weight_base_index;
					Elsif (i_wb_addr = BIAS_INDEX_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= bias_index;
					Elsif (i_wb_addr = N_INPUTS_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= n_inputs_reg;
					Elsif (i_wb_addr = SUM_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= (Others => '0'); --write-only from Ada, so read register is filled with 0s
					Elsif (i_wb_addr = SCALE_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= (Others => '0'); --write-only from Ada, so read register is filled with 0s
					Elsif (i_wb_addr = ZERO_POINT_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= (Others => '0'); --write-only from Ada, so read register is filled with 0s
					Elsif (i_wb_addr = QUANTIZED_MULTIPLIER_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= (Others => '0'); --write-only from Ada, so read register is filled with 0s
					Elsif (i_wb_addr = QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS) Then
						is_valid := '1';
						reg_rdata <= (Others => '0'); --write-only from Ada, so read register is filled with 0s							
					
					--Tensor windows are valid only when idle (npu_busy='0')
					Elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) And
						unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						is_valid := '1';
						is_tensor := '1';
						wb_rsel <= "001";

					Elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_B_BASE) And
						unsigned(i_wb_addr) < unsigned(TENSOR_B_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						is_valid := '1';
						is_tensor := '1';
						wb_rsel <= "010";

					Elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_C_BASE) And
						unsigned(i_wb_addr) < unsigned(TENSOR_C_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						is_valid := '1';
						is_tensor := '1';
						wb_rsel <= "011";

					Elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) And
						unsigned(i_wb_addr) < unsigned(TENSOR_R_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						is_valid := '1';
						is_tensor := '1';
						wb_rsel <= "100";
					End If;

					--Gate tensor ACKs while NPU is busy
					If (is_valid = '1') Then
						If (is_tensor = '1' And npu_busy = '1') Then
							ack_r <= '0';
						Else
							ack_r <= '1';
						End If;
					End If;
				End If;
			End If;
		End If;
	End Process;

	o_wb_ack <= ack_r;

	With wb_rsel Select
		o_wb_data <= reg_rdata When "000",
		tensor_A_wb_rdata When "001",
		tensor_B_wb_rdata When "010",
		tensor_C_wb_rdata When "011",
		tensor_R_wb_rdata When Others;
	--Wishbone register write process
	Process (clk)
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				ctrl_reg <= (Others => '0');
				pool_base_index <= (Others => '0');
				r_out_index <= (Others => '0');
				word_index_reg <= (Others => '0');
				sum_param_reg <= (Others => '0');
				softmax_mode_reg <= (Others => '0');
				weight_base_index <= (Others => '0');
				bias_index <= (Others => '0');
				n_inputs_reg <= (Others => '0');
				bus_dim_we <= '0';
				bus_dim_data <= (Others => '0');
				scale <= (Others => '0');
				zero_point <= (Others => '0');
				quantized_multiplier <= (Others => '0');
				quantized_multiplier_right_shift <= (Others => '0');
			Else
				bus_dim_we <= '0';

				If (wb_req = '1' And i_wb_we = '1') Then
					--Registers are always writable (NPU busy status does not matter)
					If (i_wb_addr = CTRL_REG_ADDRESS) Then
						ctrl_reg <= i_wb_data;
					Elsif (i_wb_addr = DIM_REG_ADDRESS) Then
						bus_dim_we <= '1';
						bus_dim_data <= i_wb_data(7 Downto 0);
					Elsif (i_wb_addr = POOL_BASE_INDEX_ADDRESS) Then
						pool_base_index <= i_wb_data;
					Elsif (i_wb_addr = R_OUT_INDEX_ADDRESS) Then
						r_out_index <= i_wb_data;
					Elsif (i_wb_addr = WORD_INDEX_ADDRESS) Then
						word_index_reg <= i_wb_data;
					Elsif (i_wb_addr = SUM_REG_ADDRESS) Then
						sum_param_reg <= i_wb_data; --Ada writes calculated sum before Pass 2 of SoftMax
					Elsif (i_wb_addr = SOFTMAX_MODE_ADDRESS) Then
						softmax_mode_reg <= i_wb_data; --Ada sets mode: 0=EXP, 1=DIV
					Elsif (i_wb_addr = WEIGHT_BASE_INDEX_ADDRESS) Then
						weight_base_index <= i_wb_data;
					Elsif (i_wb_addr = BIAS_INDEX_ADDRESS) Then
						bias_index <= i_wb_data;
					Elsif (i_wb_addr = N_INPUTS_ADDRESS) Then
						n_inputs_reg <= i_wb_data;
					Elsif (i_wb_addr = SCALE_REG_ADDRESS) Then
						scale <= i_wb_data;
					Elsif (i_wb_addr = ZERO_POINT_REG_ADDRESS) Then
						zero_point <= i_wb_data;
					Elsif (i_wb_addr = QUANTIZED_MULTIPLIER_REG_ADDRESS) Then
						quantized_multiplier <= i_wb_data;
					Elsif (i_wb_addr = QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS) Then
						quantized_multiplier_right_shift <= i_wb_data;
					End If;
				End If;
			End If;
		End If;
	End Process;

	--Unified FSM process
	Process (clk)
		Variable elem_index : unsigned(15 Downto 0); --flat index into A/R
		Variable word_index : unsigned(15 Downto 0); --32-bit word index (unsigned)
		Variable byte_sel : unsigned(1 Downto 0); --byte lane select 0 to 3
		Variable packed_word : Std_ulogic_vector(31 Downto 0); --fetched 32-bit word
		Variable sel_byte : Std_ulogic_vector(7 Downto 0); --Byte selected from word during pooling
		Variable current_input_index : unsigned(15 Downto 0); --current index in A for dense (word index and byte offset)
		Variable current_weight_index : unsigned(15 Downto 0); --current weight index in B for dense (word index and byte offset)

		Variable input_word_index : unsigned(15 Downto 0); --input word index (extracted from current_input_index)
		Variable weight_word_index : unsigned(15 Downto 0); --weight word index (extracted from current_weight_index)

		Variable input_byte_off : Natural Range 0 To 3; --input word byte offset (extracted from current_input_index)
		Variable weight_byte_off : Natural Range 0 To 3; --weight word byte offset (extracted from current weight index)

		Variable input_shift_bits : Natural; --input byte offset converted to bits
		Variable weight_shift_bits : Natural; --weight byte offset converted to bits

		Variable input_word_shifted : Std_ulogic_vector(31 Downto 0);
		Variable weight_word_shifted : Std_ulogic_vector(31 Downto 0);

		Variable remaining_u : unsigned(15 Downto 0); --inputs left for this neuron
		Variable remaining_i : Integer; --inputs left for this neuron (integer)
		Variable lanes_i : Integer; --lanes used for this iteration (max 4)
		Variable lanes_av_in : Integer; --input lanes available before crossiing into next word
		Variable lanes_av_wt : Integer; --weight lanes available (before crossing into next word)
		Variable lanes_u : unsigned(15 Downto 0); --lanes_i but unsigned
		--lanes help calculate how many inputs and weights for a neuron can be calculated
		Variable next_count : unsigned(15 Downto 0); --number of inputs left to be processed. Helps with deciding if we want to continue with mac state or if we can add
		--Variable prod	:	signed(63 downto 0);	--Intermediate product from dense_requantize
		--the bias
		--also, new value for mac_counter
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				state <= S_IDLE;
				--status_reg <= (others => '0');
				op_code_reg <= (Others => '0');
				base_i_reg <= (Others => '0');
				out_i_reg <= (Others => '0');
				din_reg <= (Others => '0');
				word_i_reg <= (Others => '0');
				softmax_mode_latched <= '0';

				weight_base_reg <= (Others => '0');
				bias_index_reg <= (Others => '0');
				n_inputs_latched <= (Others => '0');
				mac_counter <= (Others => '0');
				accumulator <= (Others => '0');
				bias_val_reg <= (Others => '0');
				dense_result <= (Others => '0');

				dense_lane_count <= (Others => '0');

				num00_reg <= (Others => '0');
				num01_reg <= (Others => '0');
				num10_reg <= (Others => '0');
				num11_reg <= (Others => '0');
				r8_reg <= (Others => '0');

				a_w_reg <= (Others => '0');
				r_w_reg <= (Others => '0');

				read_index <= (Others => '0');
				read_index_lat <= (Others => '0');
				byte_sel_lat <= (Others => '0');

				pool_dim_we <= '0';

				tensor_A_npu_addr <= (Others => '0');
				tensor_B_npu_addr <= (Others => '0');
				tensor_C_npu_addr <= (Others => '0');
				
				scale_lat <= (Others => '0');
				zero_point_lat <= (Others => '0');
				quantized_multiplier_lat <= (Others => '0');
				quantized_multiplier_right_shift_lat <= (Others => '0');
				prod <= (Others => '0');

			Else
				pool_dim_we <= '0';

				Case state Is
					When S_IDLE =>
						--status_reg(0) <= '0';                --not busy
						If (start_cmd = '1') Then
							status_reg(1) <= '0'; --clear done
							state <= S_CAPTURE; --capture parameters
						End If;

					When S_CAPTURE =>
						--status_reg(0) <= '1'; --The NPU is marked busy once the capture stage begins
						op_code_reg <= ctrl_reg(5 Downto 1);
						din_reg <= unsigned(dim_side_len_8);
						base_i_reg <= unsigned(pool_base_index(15 Downto 0));
						out_i_reg <= unsigned(r_out_index (15 Downto 0));
						word_i_reg <= unsigned(word_index_reg(15 Downto 0));
						softmax_mode_latched <= softmax_mode_reg(0); --Latch softmax mode

						weight_base_reg <= unsigned(weight_base_index(15 Downto 0));
						bias_index_reg <= unsigned(bias_index(15 Downto 0));
						n_inputs_latched <= unsigned(n_inputs_reg(15 Downto 0));

						scale_lat <= signed(scale);
						zero_point_lat <= signed(zero_point);
						quantized_multiplier_lat <= signed(quantized_multiplier);
						quantized_multiplier_right_shift_lat <= unsigned(quantized_multiplier_right_shift (7 downto 0));
						
						read_index <= (Others => '0');
						state <= S_OP_CODE_BRANCH;

					When S_OP_CODE_BRANCH =>
						--Decode opcode and branch to appropriate datapath
						If (op_code_reg = OP_NOP) Then
							state <= S_DONE;
						Elsif (op_code_reg = OP_MAXPOOL) Or (op_code_reg = OP_AVGPOOL) Then
							state <= S_P_READ_REQ;
						Elsif (op_code_reg = OP_SIGMOID) Or (op_code_reg = OP_RELU) Or (op_code_reg = OP_SOFTMAX) Then
							state <= S_ACT_READ_REQ;
						Elsif (op_code_reg = OP_DENSE) Then
							state <= S_DENSE_INIT;
						Else
							--status_reg(0) <= '0';
							status_reg(1) <= '1';
							state <= S_IDLE;
						End If;

						--Pooling States------------------------------------------------------

					When S_P_READ_REQ =>

						elem_index := compute_pooling_flat_index_2x2(read_index, base_i_reg, din_reg);
						--Request BRAM read for tensor_A word
						word_index := resize(elem_index(15 Downto 2), word_index'length);
						byte_sel := elem_index(1 Downto 0);

						tensor_A_npu_addr <= resize(word_index, tensor_A_npu_addr'length);

						--Latch which byte and which slot this read corresponds to
						byte_sel_lat <= byte_sel;
						read_index_lat <= read_index;
						state <= S_P_READ_WAIT;

						--Wait a clock cycle for BRAM read to complete
					When S_P_READ_WAIT =>
						state <= S_P_READ_CAP;

					When S_P_READ_CAP =>
						--Consume BRAM data (available 1 cycle after address request)
						packed_word := tensor_A_npu_rdata;
						sel_byte := Std_ulogic_vector(
							shift_right(unsigned(packed_word), to_integer(byte_sel_lat) * 8)(7 Downto 0)
							);
						--Store into the appropriate register
						Case read_index_lat Is
							When "00" => num00_reg <= signed(sel_byte);
							When "01" => num01_reg <= signed(sel_byte);
							When "10" => num10_reg <= signed(sel_byte);
							When Others => num11_reg <= signed(sel_byte);
						End Case;

						--Advance or move to compute
						If (read_index_lat = "11") Then
							state <= S_P_CALC;
						Else
							read_index <= read_index_lat + 1;
							state <= S_P_READ_REQ;
						End If;

					When S_P_CALC =>
						--Pooling compute: avg or max across 2x2, result in r8_reg
						If (op_code_reg = OP_AVGPOOL) Then
							r8_reg <= avgpool4(num00_reg, num01_reg, num10_reg, num11_reg);
						Else
							r8_reg <= maxpool4(num00_reg, num01_reg, num10_reg, num11_reg);
						End If;
						state <= S_P_WRITE;

					When S_P_WRITE =>
						state <= S_DONE;

						--Actiation states--------------------------------------------

					When S_ACT_READ_REQ =>
						--Request tensor_A word
						tensor_A_npu_addr <= resize(word_i_reg, tensor_A_npu_addr'length);
						state <= S_ACT_READ_WAIT;
						--Wait a clock cycle for BRAM read to complete
					When S_ACT_READ_WAIT =>
						state <= S_ACT_CALC;

					When S_ACT_CALC =>

						--Select function based on opcode and softmax mode
						If (op_code_reg = OP_RELU) Then
							r_w_reg <= relu_packed_word(tensor_A_npu_rdata);
						Elsif (op_code_reg = OP_SIGMOID) Then
							r_w_reg <= sigmoid_packed_word(tensor_A_npu_rdata);
						Elsif (op_code_reg = OP_SOFTMAX) Then
							--Determine softmax mode determine for finding exponent (pass 1) or division (pass 2)
							If (softmax_mode_latched = '0') Then
								--Exponent phase (Pass 1)
								r_w_reg <= softmax_exponent_packed_word(tensor_A_npu_rdata);
							Else
								--Division phase (divide by sum) (Pass 2)
								r_w_reg <= softmax_div_by_sum_packed_word(tensor_A_npu_rdata, unsigned(sum_param_reg(15 Downto 0)));
							End If;
						End If;

						state <= S_ACT_WRITE;

					When S_ACT_WRITE =>
						state <= S_DONE;

						--Dense states----------------------------------------------------------

					When S_DENSE_INIT =>
						--Request bias word from tensor C
						--tensor_C_npu_rdata is available one cycle after tensor_C_npu_addr is set
						tensor_C_npu_addr <= resize(bias_index_reg, tensor_C_npu_addr'length); --int32 bias (word) index
						state <= S_DENSE_BIAS_WAIT;
					When S_DENSE_BIAS_WAIT =>
						state <= S_DENSE_BIAS_READ;
					When S_DENSE_BIAS_READ =>
						--Bias word is available from BRAM, so we read it
						--byte_sel := bias_index_reg(1 Downto 0);
						packed_word := tensor_C_npu_rdata;
						--bias_val_reg <= extract_byte_from_word(packed_word, to_integer(byte_sel));
						bias_val_reg <= signed(packed_word);
						--Reset dense accumulators/counters after bias has been captured
						accumulator <= (Others => '0');
						mac_counter <= (Others => '0');
						dense_lane_count <= (Others => '0');

						state <= S_DENSE_FETCH;

					When S_DENSE_FETCH =>
						--Fetch a packed group of inputs/weights from A and B for multiplication and accumulation

						--Current element indices
						current_input_index := word_i_reg + mac_counter;
						current_weight_index := weight_base_reg + mac_counter;

						input_word_index := resize(current_input_index(15 Downto 2), input_word_index'length);
						weight_word_index := resize(current_weight_index(15 Downto 2), weight_word_index'length);

						--Request words from tensors A and B
						--tensor_A_npu_rdata and tensor_B_npu_rdata are available in the next cycle
						tensor_A_npu_addr <= resize(input_word_index, tensor_A_npu_addr'length);
						tensor_B_npu_addr <= resize(weight_word_index, tensor_B_npu_addr'length);

						--Byte offset inside the packed word
						input_byte_off := to_integer(current_input_index(1 Downto 0));
						weight_byte_off := to_integer(current_weight_index(1 Downto 0));

						--Compute how many lanes we can safely process this step
						--Don't want exceed remaining inputs
						--Don't want to cross a 32-bit word boundary
						remaining_u := n_inputs_latched - mac_counter; --remaining inputs to process = total inputs to process - inputs pricessed already
						remaining_i := to_integer(remaining_u);

						lanes_av_in := 4 - Integer(input_byte_off);
						lanes_av_wt := 4 - Integer(weight_byte_off);

						lanes_i := 4; --lanes_i = min(4,remaining_i,lanes_av_in,lanes_av_wt)
						If (remaining_i < lanes_i) Then
							lanes_i := remaining_i;
						End If;
						If (lanes_av_in < lanes_i) Then
							lanes_i := lanes_av_in;
						End If;
						If (lanes_av_wt < lanes_i) Then
							lanes_i := lanes_av_wt;
						End If;

						dense_lane_count <= to_unsigned(lanes_i, dense_lane_count'length);

						state <= S_DENSE_FETCH_WAIT;

					When S_DENSE_FETCH_WAIT =>
						state <= S_DENSE_MAC;

					When S_DENSE_MAC =>

						input_shift_bits := input_byte_off * 8;
						weight_shift_bits := weight_byte_off * 8;

						input_word_shifted := Std_ulogic_vector(shift_right(unsigned(tensor_A_npu_rdata), input_shift_bits));
						weight_word_shifted := Std_ulogic_vector(shift_right(unsigned(tensor_B_npu_rdata), weight_shift_bits));

						accumulator <= dense_mac4(
							accumulator,
							input_word_shifted,
							weight_word_shifted,
							resize(zero_point_lat, 8),
							to_integer(dense_lane_count)
							);

						--Advance by the number of lanes processed this cycle
						lanes_u := resize(dense_lane_count, lanes_u'length);
						next_count := mac_counter + lanes_u; --next_count = number of inputs processed till the previous iteration + pairs process in this iteration 
						mac_counter <= next_count; --update number of inputs processed

						--Check if all N inputs processed
						--Loop until all inputs processed
						If (next_count >= n_inputs_latched) Then
							state <= S_DENSE_BIAS_PRODUCT;
						Else
							state <= S_DENSE_FETCH;
						End If;

					When S_DENSE_BIAS_PRODUCT =>
						--Add bias and saturate to Q0.7 range
						--dense_result <= dense_add_bias_and_saturate(accumulator, bias_val_reg);
						prod <= dense_requantize_product(accumulator, bias_val_reg, quantized_multiplier_lat);
						state <= S_DENSE_BIAS_CLAMP;
					When S_DENSE_BIAS_CLAMP =>
						dense_result <= dense_requantize_clamp(prod,quantized_multiplier_right_shift_lat);
						state <= S_DENSE_WRITE;

					When S_DENSE_WRITE =>
						state <= S_DONE;

					When S_DONE =>
						--status_reg(0) <= '0';
						status_reg(1) <= '1';
						state <= S_IDLE;

				End Case;
			End If;
		End If;
	End Process;
	--When npu_busy='0': WB can read/write tensor windows.
	--When npu_busy='1': NPU owns the tensor memories.
	--Tensor A: WB R/W (when idle) + NPU read (+ NPU in-place write (Softmax EXP))
	Process (clk)
		Variable tensor_offset : Natural;
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				tensor_A_wb_rdata <= (Others => '0');
				tensor_A_npu_rdata <= (Others => '0');
			Else
				If (npu_busy = '0') Then
					--WB 
					If (wb_req = '1' And
						unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) And unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
						If (tensor_offset < TENSOR_WORDS) Then
							If (i_wb_we = '1') Then
								tensor_A_mem(tensor_offset) <= i_wb_data;
							End If;
							tensor_A_wb_rdata <= tensor_A_mem(tensor_offset);
						Else
							tensor_A_wb_rdata <= (Others => '0');
						End If;
					End If;

				Else
					--NPU port (read)
					If (to_integer(tensor_A_npu_addr) < TENSOR_WORDS) Then
						tensor_A_npu_rdata <= tensor_A_mem(to_integer(tensor_A_npu_addr));
					Else
						tensor_A_npu_rdata <= (Others => '0');
					End If;

					--NPU in-place write for Softmax EXP (Pass 1)
					If (state = S_ACT_WRITE) And (op_code_reg = OP_SOFTMAX) And (softmax_mode_latched = '0') Then
						If (to_integer(word_i_reg) < TENSOR_WORDS) Then
							tensor_A_mem(to_integer(word_i_reg)) <= r_w_reg;
						End If;
					End If;
				End If;
			End If;
		End If;
	End Process;

	--Tensor B: WB R/W (when idle) + NPU read
	Process (clk)
		Variable tensor_offset : Natural;
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				tensor_B_wb_rdata <= (Others => '0');
				tensor_B_npu_rdata <= (Others => '0');
			Else
				If (npu_busy = '0') Then
					If (wb_req = '1' And
						unsigned(i_wb_addr) >= unsigned(TENSOR_B_BASE) And unsigned(i_wb_addr) < unsigned(TENSOR_B_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_B_BASE);
						If (tensor_offset < TENSOR_WORDS) Then
							If (i_wb_we = '1') Then
								tensor_B_mem(tensor_offset) <= i_wb_data;
							End If;
							tensor_B_wb_rdata <= tensor_B_mem(tensor_offset);
						Else
							tensor_B_wb_rdata <= (Others => '0');
						End If;
					End If;
				Else
					If (to_integer(tensor_B_npu_addr) < TENSOR_WORDS) Then
						tensor_B_npu_rdata <= tensor_B_mem(to_integer(tensor_B_npu_addr));
					Else
						tensor_B_npu_rdata <= (Others => '0');
					End If;
				End If;
			End If;
		End If;
	End Process;

	--Tensor C: WB R/W (when idle) + NPU read
	Process (clk)
		Variable tensor_offset : Natural;
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				tensor_C_wb_rdata <= (Others => '0');
				tensor_C_npu_rdata <= (Others => '0');
			Else
				If (npu_busy = '0') Then
					If (wb_req = '1' And
						unsigned(i_wb_addr) >= unsigned(TENSOR_C_BASE) And unsigned(i_wb_addr) < unsigned(TENSOR_C_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_C_BASE);
						If (tensor_offset < TENSOR_WORDS) Then
							If (i_wb_we = '1') Then
								tensor_C_mem(tensor_offset) <= i_wb_data;
							End If;
							tensor_C_wb_rdata <= tensor_C_mem(tensor_offset);
						Else
							tensor_C_wb_rdata <= (Others => '0');
						End If;
					End If;
				Else
					If (to_integer(tensor_C_npu_addr) < TENSOR_WORDS) Then
						tensor_C_npu_rdata <= tensor_C_mem(to_integer(tensor_C_npu_addr));
					Else
						tensor_C_npu_rdata <= (Others => '0');
					End If;
				End If;
			End If;
		End If;
	End Process;

	--Tensor R: WB read (when idle) + NPU write
	--NPU writes happen in these states:
	--S_ACT_WRITE     : write one packed word at word index word_i_reg (except Softmax EXP pass)
	--S_P_WRITE       : write one int8 at element index out_i_reg
	--S_DENSE_WRITE   : write one int8 at element index out_i_reg
	--TODO: Add convolution
	Process (clk)
		Variable tensor_offset : Natural;
		Variable w_index : Natural;
		Variable byte_sel : Natural Range 0 To 3;
		Variable word_tmp : Std_ulogic_vector(31 Downto 0);
	Begin
		If (rising_edge(clk)) Then
			If (reset = '1') Then
				tensor_R_wb_rdata <= (Others => '0');
			Else
				If (npu_busy = '0') Then
					--WB read port
					If (wb_req = '1' And
						unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) And unsigned(i_wb_addr) < unsigned(TENSOR_R_BASE) + to_unsigned(TENSOR_BYTES, 32)) Then
						tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_R_BASE);
						If (tensor_offset < TENSOR_WORDS) Then
							tensor_R_wb_rdata <= tensor_R_mem(tensor_offset);
						Else
							tensor_R_wb_rdata <= (Others => '0');
						End If;
					End If;

				Else
					--NPU write
					If (state = S_P_WRITE) Then
						--Write a single signed int8 into the packed word at element index out_i_reg
						w_index := to_integer(out_i_reg(15 Downto 2));
						byte_sel := to_integer(out_i_reg(1 Downto 0));
						If (w_index < TENSOR_WORDS) Then
							word_tmp := tensor_R_mem(w_index);
							Case byte_sel Is
								When 0 => word_tmp(7 Downto 0) := Std_ulogic_vector(r8_reg);
								When 1 => word_tmp(15 Downto 8) := Std_ulogic_vector(r8_reg);
								When 2 => word_tmp(23 Downto 16) := Std_ulogic_vector(r8_reg);
								When Others => word_tmp(31 Downto 24) := Std_ulogic_vector(r8_reg);
							End Case;
							tensor_R_mem(w_index) <= word_tmp;
						End If;

					Elsif (state = S_DENSE_WRITE) Then
						--Write dense_result (signed int8) at element index out_i_reg
						w_index := to_integer(out_i_reg(15 Downto 2));
						byte_sel := to_integer(out_i_reg(1 Downto 0));
						If (w_index < TENSOR_WORDS) Then
							word_tmp := tensor_R_mem(w_index);
							Case byte_sel Is
								When 0 => word_tmp(7 Downto 0) := Std_ulogic_vector(dense_result);
								When 1 => word_tmp(15 Downto 8) := Std_ulogic_vector(dense_result);
								When 2 => word_tmp(23 Downto 16) := Std_ulogic_vector(dense_result);
								When Others => word_tmp(31 Downto 24) := Std_ulogic_vector(dense_result);
							End Case;
							tensor_R_mem(w_index) <= word_tmp;
						End If;

					Elsif (state = S_ACT_WRITE) Then
						--Softmax EXP is in-place on A, so only write to R for all other activation cases
						If (Not (op_code_reg = OP_SOFTMAX And softmax_mode_latched = '0')) Then
							If (to_integer(word_i_reg) < TENSOR_WORDS) Then
								tensor_R_mem(to_integer(word_i_reg)) <= r_w_reg;
							End If;
						End If;
					End If;
				End If;
			End If;
		End If;
	End Process;

End Architecture;
