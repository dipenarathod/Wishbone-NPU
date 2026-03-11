LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.tensor_operations_basic_arithmetic.ALL; --import opcodes/constants and packed int8 add/sub
USE work.tensor_operations_pooling.ALL; --import pooling opcodes & helpers (read/max/avg)
USE work.tensor_operations_activation.ALL;
USE work.tensor_operations_dense.ALL;
USE work.tensor_operations_conv2d.ALL;
--Revised address for tensors B, C, and R to allow addressing for the new 100x100 tensors (2500 words)
ENTITY wb_peripheral_top IS
	GENERIC (
		BASE_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000000"; --peripheral base (informational)
		TENSOR_A_BASE : Std_ulogic_vector(31 DOWNTO 0) := x"90000600"; --A window base
		TENSOR_B_BASE : Std_ulogic_vector(31 DOWNTO 0) := x"90002D10"; --B window base
		TENSOR_C_BASE : Std_ulogic_vector(31 DOWNTO 0) := x"9000B9B0"; --C window base
		TENSOR_R_BASE : Std_ulogic_vector(31 DOWNTO 0) := x"9000D8F0"; --R window base
		CTRL_REG_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000008"; --[0]=start, [5:1]=opcode
		STATUS_REG_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"9000000C"; --[0]=busy, [1]=done (sticky)
		DIM_REG_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000010"; --N (LSB 8 bits). Conv: input feature width
		POOL_BASE_INDEX_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000014"; --top-left index in A
		R_OUT_INDEX_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000018"; --out index in R
		WORD_INDEX_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"9000001C"; --word index for tensor indexing
		SUM_REG_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000020"; --Softmax sum parameter (write-only)
		SOFTMAX_MODE_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000024"; --Softmax mode: 0=EXP, 1=DIV
		WEIGHT_BASE_INDEX_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000028"; --Dense: weight base index in B
		BIAS_INDEX_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"9000002C"; --Dense: bias word index in C
		N_INPUTS_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000030"; --Dense: number of inputs N. Conv: Number of input channels
		ZERO_POINT_REG_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"9000003C"; --Zero-point register
		QUANTIZED_MULTIPLIER_REG_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000040"; --Quantized multiplier
		QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000044"; --Right shift for Quantized multiplier
		N_FILTERS_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000048"; --Number of output channels in the conv2d layer
		WORDS_TO_COPY_FROM_R_TO_A_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"9000004C"; --total words to copy from R to A
		REQUANT_PROD_HI_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000050"; --total words to copy from R to A
		REQUANT_PROD_LO_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000054"; --total words to copy from R to A
		REQUANT_RESULT_32_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"9000005C"; --total words to copy from R to A
		REQUANT_RESULT_8_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000060"; --total words to copy from R to A
		ACCUMULATOR_ADDRESS : Std_ulogic_vector(31 DOWNTO 0) := x"90000064" --total words to copy from R to A

	);
	PORT (
		clk : IN Std_ulogic; --system clock
		reset : IN Std_ulogic; --synchronous reset
		i_wb_cyc : IN Std_ulogic; --Wishbone: cycle valid
		i_wb_stb : IN Std_ulogic; --Wishbone: strobe
		i_wb_we : IN Std_ulogic; --Wishbone: 1=write, 0=read
		i_wb_addr : IN Std_ulogic_vector(31 DOWNTO 0);--Wishbone: address
		i_wb_data : IN Std_ulogic_vector(31 DOWNTO 0);--Wishbone: write data
		o_wb_ack : OUT Std_ulogic; --Wishbone: acknowledge
		o_wb_stall : OUT Std_ulogic; --Wishbone: stall (always '0')
		o_wb_data : OUT Std_ulogic_vector(31 DOWNTO 0) --Wishbone: read data
	);
END ENTITY;

ARCHITECTURE rtl OF wb_peripheral_top IS

	CONSTANT OP_COPY_R_TO_A : Std_ulogic_vector(4 DOWNTO 0) := "11110";
	CONSTANT OP_NOP : Std_ulogic_vector(4 DOWNTO 0) := "11111";

	--Wishbone
	SIGNAL ack_r : Std_ulogic := '0';
	SIGNAL wb_req : Std_ulogic := '0'; --Variable tp combine checks (Clock is high and the slave (NPU) is selected)

	--Only allow the CPU to access tensor windows when the NPU is idle.
	--The CPU can still poll the NPU to check if it is busy.
	--
	--To make BRAM inference easier, each tensor memory is written/read from a single clocked process
	--and we multiplex the memory port between WB (when idle) and NPU (when busy).
	SIGNAL npu_busy : Std_ulogic := '0';

	--Wishbone read mux selector (latched for the transaction being acknowledged)
	--000: register readback
	--001: tensor_A window
	--010: tensor_B window
	--011: tensor_C window
	--100: tensor_R window
	SIGNAL wb_rsel : Std_ulogic_vector(2 DOWNTO 0) := (OTHERS => '0'); --select signal for tensor mux
	SIGNAL reg_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');

	--Tensors
	SIGNAL tensor_A_mem : tensor_A_mem_type := (OTHERS => (OTHERS => '0'));
	SIGNAL tensor_B_mem : tensor_B_mem_type := (OTHERS => (OTHERS => '0'));
	SIGNAL tensor_C_mem : tensor_C_mem_type := (OTHERS => (OTHERS => '0'));
	SIGNAL tensor_R_mem : tensor_R_mem_type := (OTHERS => (OTHERS => '0'));

	--BRAM inference hints
	ATTRIBUTE ram_style : STRING;
	ATTRIBUTE syn_ramstyle : STRING;

	ATTRIBUTE ram_style OF tensor_A_mem : SIGNAL IS "BLOCK";
	ATTRIBUTE ram_style OF tensor_B_mem : SIGNAL IS "BLOCK";
	ATTRIBUTE ram_style OF tensor_C_mem : SIGNAL IS "BLOCK";
	ATTRIBUTE ram_style OF tensor_R_mem : SIGNAL IS "BLOCK";

	ATTRIBUTE syn_ramstyle OF tensor_A_mem : SIGNAL IS "block_ram";
	ATTRIBUTE syn_ramstyle OF tensor_B_mem : SIGNAL IS "block_ram";
	ATTRIBUTE syn_ramstyle OF tensor_C_mem : SIGNAL IS "block_ram";
	ATTRIBUTE syn_ramstyle OF tensor_R_mem : SIGNAL IS "block_ram";

	--Read data for Wishbone access to tensors (valid when wb_rsel selects them for reading)
	SIGNAL tensor_A_wb_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tensor_B_wb_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tensor_C_wb_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tensor_R_wb_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');

	--NPU-side BRAM ports (synchronous read, 1-cycle latency)
	--16-bit addresses can address 2^16 = 64KB worth of memort. Change width to more depending on needs
	SIGNAL tensor_A_npu_addr : unsigned(15 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tensor_A_npu_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');

	SIGNAL tensor_B_npu_addr : unsigned(15 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tensor_B_npu_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');

	SIGNAL tensor_C_npu_addr : unsigned(15 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tensor_C_npu_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');

	SIGNAL tensor_R_npu_addr : unsigned(15 DOWNTO 0) := (OTHERS => '0');
	SIGNAL tensor_R_npu_rdata : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');

	--Control and status registers
	SIGNAL ctrl_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --[0]=start, [5:1]=opcode
	SIGNAL status_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --[0]=busy, [1]=done
	SIGNAL dim_side_len_8 : Std_ulogic_vector(7 DOWNTO 0) := (OTHERS => '0'); --N side length
	SIGNAL dim_side_len_bus : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --zero-extended N

	--Pooling address parameters
	SIGNAL pool_base_index : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --A flat index (top-left)
	SIGNAL pool_row_start_index : unsigned (15 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pool_out_dim : unsigned (7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pool_out_row : unsigned (7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pool_out_col : unsigned (7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL r_out_index : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --R flat index

	--Elementwise word index
	SIGNAL word_index_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --packed word index

	--Softmax parameters (write-only from Ada)
	SIGNAL sum_param_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --Sum calculated by Ada
	SIGNAL softmax_mode_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --Flag to differ between exponent and div mode. 0=EXP, 1=DIV
	--Using anpther opcode is possible, but I (DAR) don't suggest wasting an opcode
	--Start edge detection (one-cycle pulse)
	--ctrl0_prev is introduced to ensure a new command is not triggered every cycle (when ctrl is set)
	SIGNAL start_cmd : Std_ulogic := '0';
	SIGNAL ctrl0_prev : Std_ulogic := '0';

	--Muxed write paths for DIM (allowing bus or internal updates)
	--Will be useful when there is a dedicated pooling/conv unit
	SIGNAL bus_dim_we : Std_ulogic := '0';
	SIGNAL bus_dim_data : Std_ulogic_vector(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL pool_dim_we : Std_ulogic := '0';
	SIGNAL pool_dim_data : Std_ulogic_vector(7 DOWNTO 0) := (OTHERS => '0');

	--Dense layer operation registers
	SIGNAL weight_base_index : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --Weight base element index in B
	SIGNAL bias_index : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --Bias element index in C
	SIGNAL n_inputs_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --Number of inputs for dense layer
	SIGNAL weight_base_reg : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --weight base element index
	SIGNAL bias_index_reg : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --bias element index
	SIGNAL n_inputs_lat : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --number of inputs
	SIGNAL mac_counter : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --MAC loop counter
	SIGNAL accumulator : signed(31 DOWNTO 0) := (OTHERS => '0'); --32-bit accumulator
	SIGNAL bias_val_reg : signed(31 DOWNTO 0) := (OTHERS => '0'); --bias value. ALSO USED FOR CONV
	SIGNAL prod : signed(63 DOWNTO 0); --Intermediate product from dense_requantize
	SIGNAL requantize_32 : signed(31 DOWNTO 0); --Shift product according to requantization

	SIGNAL input_byte_sel_lat : NATURAL RANGE 0 TO 3; --input word byte offset (extracted from current_input_index). Reused for Conv
	SIGNAL weight_byte_sel_lat : NATURAL RANGE 0 TO 3; --weight word byte offset (extracted from current weight index). Reused for Conv

	SIGNAL dense_lane_count : unsigned(2 DOWNTO 0) := (OTHERS => '0'); --how many lanes (pairs) of inputs and weights are valid this iteration (without crossing word boundary or into other neuron's weights) Upto 4

	--Copy R to A signals
	SIGNAL total_words_to_copy_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --total words to copy from R to A
	SIGNAL total_words_to_copy_lat : unsigned(31 DOWNTO 0) := (OTHERS => '0'); 
	SIGNAL total_words_in_tensor : unsigned(31 DOWNTO 0) := (OTHERS => '0'); --total word elements in input/ouptut tensor
	SIGNAL total_int8_elements_in_tensor : unsigned(31 DOWNTO 0) := (OTHERS => '0'); --total int8 elements in input/output tensor
	--indices to move between start of consecutive input channels for conv

	--Pooling datapath registers (2x2 window and result)
	SIGNAL num00_reg, num01_reg, num10_reg, num11_reg : signed(7 DOWNTO 0) := (OTHERS => '0');
	SIGNAL r_8_reg : signed(7 DOWNTO 0) := (OTHERS => '0');

	--Registers for packed word operations
	SIGNAL r_w_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');

	SIGNAL read_index : unsigned(1 DOWNTO 0) := (OTHERS => '0');
	SIGNAL read_index_lat : unsigned(1 DOWNTO 0) := (OTHERS => '0'); --latch variant for read_index
	SIGNAL byte_sel_lat : unsigned(1 DOWNTO 0) := (OTHERS => '0'); --latch variant for byte_sel

	--Quantization helper registers
	SIGNAL zero_point : std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0');
	SIGNAL quantized_multiplier : std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --(lhs_scale * rhs_scale / result_scale) from GEMMlowp's equation 5 is a real number. This multiplier register holds the quanztized version of the real multipler
	SIGNAL quantized_multiplier_right_shift : std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --right shifs required to convert quantized multiplier to the real multiplier
 
	SIGNAL zero_point_lat : signed(31 DOWNTO 0) := (OTHERS => '0'); --zero point value latched
	SIGNAL quantized_multiplier_lat : signed(31 DOWNTO 0) := (OTHERS => '0'); --quantized multipier latched
	SIGNAL quantized_multiplier_right_shift_lat : unsigned(7 DOWNTO 0) := (OTHERS => '0'); --right shift latched
 
	--Conv helper registers

	SIGNAL n_filters_reg : Std_ulogic_vector(31 DOWNTO 0) := (OTHERS => '0'); --number of output channels
	SIGNAL n_filters_lat : unsigned(15 DOWNTO 0) := (OTHERS => '0');
	SIGNAL conv_kernel_row : unsigned(1 DOWNTO 0) := (OTHERS => '0'); --kernel row we are processing
	SIGNAL conv_kernel_col : unsigned(1 DOWNTO 0) := (OTHERS => '0'); --kernel col we are processing
	SIGNAL conv_input_channel : unsigned (7 DOWNTO 0) := (OTHERS => '0'); --Number of the input channel being processed
	SIGNAL conv_row_ptr : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --Flat index of the first element in current row of input tensor/feature (index into A)
	SIGNAL conv_weight_counter : unsigned(31 DOWNTO 0) := (OTHERS => '0'); --Flat index in the kernel we are multiplying (in B). Go from 0 to 9
 
	SIGNAL conv_lane_count : unsigned (2 DOWNTO 0); --How many lanes (pairs) of input channel and filters can we process this iteration without crossing boundary/into the next input or filter (upto 4)
	--Same as dense logic
	SIGNAL conv_filter_index : unsigned(15 DOWNTO 0); --Keep track of the filter number we are processing
	SIGNAL filter_weight_base : unsigned (31 DOWNTO 0); --starting weight element index in tensor B for the current filter
	SIGNAL filter_stride : unsigned (15 DOWNTO 0); --stride to jump from k'th filter to (k+1)'th filter (int8 jump, not word index jump)
	SIGNAL out_filter_stride : unsigned (15 DOWNTO 0); --stride to jump from where to write result for k'th filter to where to write result for(k+1)'th filter (int8 jump, not word index jump)
	SIGNAL conv_out_row : unsigned(7 DOWNTO 0) := (OTHERS => '0'); --current output row
	SIGNAL conv_out_col : unsigned(7 DOWNTO 0) := (OTHERS => '0'); --current output col
	SIGNAL conv_n_out : unsigned(7 DOWNTO 0) := (OTHERS => '0'); --N - 2 (output side length)
	SIGNAL conv_pixel_out_base : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --output index for current pixel
	--Address helper: translate byte address to word offset within a tensor window
	FUNCTION get_tensor_offset(addr, base : Std_ulogic_vector(31 DOWNTO 0)) RETURN NATURAL IS
	VARIABLE offset : unsigned(31 DOWNTO 0);
BEGIN
	offset := unsigned(addr) - unsigned(base); --word + byte offset (relative position of element from base address)
	--return to_integer(offset(11 downto 2)); --just the word offset RETURN to_integer(shift_right(offset, 2)); --Right shift 2 removes they byte offset within a word. We are left with just the word index
END FUNCTION;

--Unified FSM state encoding
TYPE state_t IS (
S_IDLE, S_CAPTURE, S_PREPARE_PRODUCTS, S_OP_CODE_BRANCH, 
--Copy R to A
S_COPY_R_REQ, S_COPY_R_WAIT, S_COPY_R_CAP, S_COPY_A_WRITE, 
--pooling path states (added a new state, request, to make BRAM inference possible)
S_P_READ_REQ, S_P_READ_WAIT, S_P_READ_CAP, S_P_CALC, S_P_WRITE, 
--Activation path states
S_ACT_READ_REQ, S_ACT_READ_WAIT, S_ACT_CALC, S_ACT_WRITE, 
--Dense path states
S_DENSE_INIT, S_DENSE_BIAS_READ, S_DENSE_BIAS_WAIT, S_DENSE_FETCH, S_DENSE_FETCH_WAIT, S_DENSE_MAC, S_DENSE_BIAS_PRODUCT, S_DENSE_REQUANTIZE, S_DENSE_BIAS_CLAMP, S_DENSE_WRITE, 
--Conv path states
S_CONV_PREP, S_CONV_INIT, S_CONV_BIAS_READ, S_CONV_BIAS_WAIT, S_CONV_FETCH, S_CONV_FETCH_WAIT, S_CONV_MAC, S_CONV_REQUANT_PRODUCT, S_CONV_REQUANTIZE, S_CONV_REQUANT_CLAMP, S_CONV_WRITE, 
S_DONE
);
SIGNAL state : state_t := S_IDLE;

--Latched operation parameters for the active command
SIGNAL op_code_reg : Std_ulogic_vector(4 DOWNTO 0) := (OTHERS => '0'); --opcode field
SIGNAL base_i_reg : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --pooling base index
SIGNAL out_i_reg : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --output index
SIGNAL din_reg : unsigned(7 DOWNTO 0) := (OTHERS => '0'); --N (tensor side length)
SIGNAL in_i_reg : unsigned(15 DOWNTO 0) := (OTHERS => '0'); --packed word index (int8-granular for dense, word-granular for act)
SIGNAL softmax_mode_latched : Std_ulogic := '0'; --latched softmax mode

BEGIN
	--Simple, non-stalling slave peripheral
	o_wb_stall <= '0';

	--Zero-extend N for bus readback
	dim_side_len_bus <= (31 DOWNTO 8 => '0') & dim_side_len_8;

	--Expose NPU busy state
	npu_busy <= '1' WHEN state /= S_IDLE ELSE '0';
	status_reg(0) <= '1' WHEN state /= S_IDLE ELSE '0';

	--Generate a one-cycle start pulse when start=1 and not busy
	--Only trigger an operation (start_cmd = 1) when ctrl(0) is transitioning to 1 for the first time and status(0) = 0 (not busy)
	PROCESS (clk)
	BEGIN
		IF (rising_edge(clk)) THEN
			IF (reset = '1') THEN
				start_cmd <= '0';
				ctrl0_prev <= '0';
			ELSE
				start_cmd <= '0';
				IF (npu_busy = '0' AND ctrl_reg(0) = '1' AND (ctrl0_prev = '0')) THEN
					start_cmd <= '1';
				END IF;
				ctrl0_prev <= ctrl_reg(0);
			END IF;
		END IF;
	END PROCESS;

	--DIM (N) register with two write sources: pooling path or bus write
	PROCESS (clk)
		BEGIN
			IF (rising_edge(clk)) THEN
				IF (reset = '1') THEN
					dim_side_len_8 <= x"32"; --default N=50.
				ELSE
					IF (pool_dim_we = '1') THEN
						dim_side_len_8 <= pool_dim_data; --TODO: When there is a dedicated pooling unit with variable window sizes
					ELSIF (bus_dim_we = '1') THEN
						dim_side_len_8 <= bus_dim_data; --bus write-update
					END IF;
				END IF;
			END IF;
		END PROCESS;

		--Tensor window accesses are only acknowledged when npu_busy=0
		--The CPU can always access control/status registers
		--This change is to allow BRAM usage (inference) for the main four tensors

		wb_req <= i_wb_cyc AND i_wb_stb; --Clock is high and the slave (NPU) is selected

		--The acknowledgement process is combined with the tensor multiplex select logic and register reads
		PROCESS (clk)
		VARIABLE is_valid : Std_ulogic;
		VARIABLE is_tensor : Std_ulogic;

			BEGIN
				IF (rising_edge(clk)) THEN
					IF (reset = '1') THEN
						ack_r <= '0';
						wb_rsel <= (OTHERS => '0');
						reg_rdata <= (OTHERS => '0');
					ELSE
						ack_r <= '0';

						IF (wb_req = '1') THEN
							--Default
							is_valid := '0';
							is_tensor := '0';
							wb_rsel <= (OTHERS => '0');
							reg_rdata <= (OTHERS => '0');

							--Register reads
							IF (i_wb_addr = CTRL_REG_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= ctrl_reg;
							ELSIF (i_wb_addr = STATUS_REG_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= status_reg;
							ELSIF (i_wb_addr = DIM_REG_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= dim_side_len_bus;
							ELSIF (i_wb_addr = POOL_BASE_INDEX_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= pool_base_index;
							ELSIF (i_wb_addr = R_OUT_INDEX_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= r_out_index;
							ELSIF (i_wb_addr = WORD_INDEX_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= word_index_reg;
							ELSIF (i_wb_addr = SOFTMAX_MODE_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= softmax_mode_reg;
							ELSIF (i_wb_addr = WEIGHT_BASE_INDEX_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= weight_base_index;
							ELSIF (i_wb_addr = BIAS_INDEX_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= bias_index;
							ELSIF (i_wb_addr = N_INPUTS_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= n_inputs_reg;
							ELSIF (i_wb_addr = SUM_REG_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= sum_param_reg;
							ELSIF (i_wb_addr = ZERO_POINT_REG_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= zero_point;
							ELSIF (i_wb_addr = QUANTIZED_MULTIPLIER_REG_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= quantized_multiplier;
							ELSIF (i_wb_addr = QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= quantized_multiplier_right_shift; 
							ELSIF (i_wb_addr = N_FILTERS_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= n_filters_reg;
							ELSIF (i_wb_addr = WORDS_TO_COPY_FROM_R_TO_A_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= total_words_to_copy_reg;
							ELSIF (i_wb_addr = REQUANT_PROD_HI_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= std_ulogic_vector(prod(63 DOWNTO 32));
							ELSIF (i_wb_addr = REQUANT_PROD_LO_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= std_ulogic_vector(prod(31 DOWNTO 0));
							ELSIF (i_wb_addr = REQUANT_RESULT_32_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= std_ulogic_vector(requantize_32);
							ELSIF (i_wb_addr = REQUANT_RESULT_8_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= std_ulogic_vector(resize(r_8_reg, 32));
							ELSIF (i_wb_addr = ACCUMULATOR_ADDRESS) THEN
								is_valid := '1';
								reg_rdata <= std_ulogic_vector(accumulator);
								--Tensor windows are valid only when idle (npu_busy='0')
							ELSIF (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) AND
								unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE) + to_unsigned(TENSOR_A_BYTES, 32)) THEN
								is_valid := '1';
								is_tensor := '1';
								wb_rsel <= "001";

							ELSIF (unsigned(i_wb_addr) >= unsigned(TENSOR_B_BASE) AND
								unsigned(i_wb_addr) < unsigned(TENSOR_B_BASE) + to_unsigned(TENSOR_B_BYTES, 32)) THEN
								is_valid := '1';
								is_tensor := '1';
								wb_rsel <= "010";

							ELSIF (unsigned(i_wb_addr) >= unsigned(TENSOR_C_BASE) AND
								unsigned(i_wb_addr) < unsigned(TENSOR_C_BASE) + to_unsigned(TENSOR_C_BYTES, 32)) THEN
								is_valid := '1';
								is_tensor := '1';
								wb_rsel <= "011";

							ELSIF (unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) AND
								unsigned(i_wb_addr) < unsigned(TENSOR_R_BASE) + to_unsigned(TENSOR_R_BYTES, 32)) THEN
								is_valid := '1';
								is_tensor := '1';
								wb_rsel <= "100";
							END IF;

							--Gate tensor ACKs while NPU is busy
							IF (is_valid = '1') THEN
								IF (is_tensor = '1' AND npu_busy = '1') THEN
									ack_r <= '0';
								ELSE
									ack_r <= '1';
								END IF;
							END IF;
						END IF;
					END IF;
				END IF;
			END PROCESS;

			o_wb_ack <= ack_r;

			WITH wb_rsel SELECT
			o_wb_data <= reg_rdata WHEN "000", 
			             tensor_A_wb_rdata WHEN "001", 
			             tensor_B_wb_rdata WHEN "010", 
			             tensor_C_wb_rdata WHEN "011", 
			             tensor_R_wb_rdata WHEN OTHERS;
			--Wishbone register write process
			PROCESS (clk)
				BEGIN
					IF (rising_edge(clk)) THEN
						IF (reset = '1') THEN
							ctrl_reg <= (OTHERS => '0');
							pool_base_index <= (OTHERS => '0');
							r_out_index <= (OTHERS => '0');
							word_index_reg <= (OTHERS => '0');
							sum_param_reg <= (OTHERS => '0');
							softmax_mode_reg <= (OTHERS => '0');
							weight_base_index <= (OTHERS => '0');
							bias_index <= (OTHERS => '0');
							n_inputs_reg <= (OTHERS => '0');
							bus_dim_we <= '0';
							bus_dim_data <= (OTHERS => '0');
							zero_point <= (OTHERS => '0');
							quantized_multiplier <= (OTHERS => '0');
							quantized_multiplier_right_shift <= (OTHERS => '0');
							total_words_to_copy_reg <= (OTHERS => '0');
						ELSE
							bus_dim_we <= '0';

							IF (wb_req = '1' AND i_wb_we = '1') THEN
								--Registers are always writable (NPU busy status does not matter)
								IF (i_wb_addr = CTRL_REG_ADDRESS) THEN
									ctrl_reg <= i_wb_data;
								ELSIF (i_wb_addr = DIM_REG_ADDRESS) THEN
									bus_dim_we <= '1';
									bus_dim_data <= i_wb_data(7 DOWNTO 0);
								ELSIF (i_wb_addr = POOL_BASE_INDEX_ADDRESS) THEN
									pool_base_index <= i_wb_data;
								ELSIF (i_wb_addr = R_OUT_INDEX_ADDRESS) THEN
									r_out_index <= i_wb_data;
								ELSIF (i_wb_addr = WORD_INDEX_ADDRESS) THEN
									word_index_reg <= i_wb_data;
								ELSIF (i_wb_addr = SUM_REG_ADDRESS) THEN
									sum_param_reg <= i_wb_data; --Ada writes calculated sum before Pass 2 of SoftMax
								ELSIF (i_wb_addr = SOFTMAX_MODE_ADDRESS) THEN
									softmax_mode_reg <= i_wb_data; --Ada sets mode: 0=EXP, 1=DIV
								ELSIF (i_wb_addr = WEIGHT_BASE_INDEX_ADDRESS) THEN
									weight_base_index <= i_wb_data;
								ELSIF (i_wb_addr = BIAS_INDEX_ADDRESS) THEN
									bias_index <= i_wb_data;
								ELSIF (i_wb_addr = N_INPUTS_ADDRESS) THEN
									n_inputs_reg <= i_wb_data;
								ELSIF (i_wb_addr = ZERO_POINT_REG_ADDRESS) THEN
									zero_point <= i_wb_data;
								ELSIF (i_wb_addr = QUANTIZED_MULTIPLIER_REG_ADDRESS) THEN
									quantized_multiplier <= i_wb_data;
								ELSIF (i_wb_addr = QUANTIZED_MULTIPLIER_RIGHT_SHIFT_REG_ADDRESS) THEN
									quantized_multiplier_right_shift <= i_wb_data;
								ELSIF (i_wb_addr = N_FILTERS_ADDRESS) THEN
									n_filters_reg <= i_wb_data;
								ELSIF (i_wb_addr = WORDS_TO_COPY_FROM_R_TO_A_ADDRESS) THEN
									total_words_to_copy_reg <= i_wb_data; 
								END IF;
							END IF;
						END IF;
					END IF;
				END PROCESS;

				--Unified FSM process
				PROCESS (clk)
				VARIABLE current_input_index : unsigned(15 DOWNTO 0); --flat index in A (word index and byte offset)
				VARIABLE word_index : unsigned(15 DOWNTO 0); --32-bit word index (unsigned)
				VARIABLE byte_sel : unsigned(1 DOWNTO 0); --byte lane select 0 to 3
				VARIABLE packed_word : Std_ulogic_vector(31 DOWNTO 0); --fetched 32-bit word
				VARIABLE sel_byte : Std_ulogic_vector(7 DOWNTO 0); --Byte selected from word during pooling
 
				VARIABLE current_weight_index : unsigned(15 DOWNTO 0); --current weight index in B for dense and conv (word index and byte offset)

				VARIABLE input_word_index : unsigned(15 DOWNTO 0); --input word index (extracted from current_input_index)
				VARIABLE weight_word_index : unsigned(15 DOWNTO 0); --weight word index (extracted from current_weight_index)

				--Variable input_byte_off : Natural Range 0 To 3; --input word byte offset (extracted from current_input_index)
				--Variable weight_byte_off : Natural Range 0 To 3; --weight word byte offset (extracted from current weight index)

				VARIABLE input_shift_bits : NATURAL; --input byte offset converted to bits
				VARIABLE weight_shift_bits : NATURAL; --weight byte offset converted to bits

				VARIABLE input_word_shifted : Std_ulogic_vector(31 DOWNTO 0);
				VARIABLE weight_word_shifted : Std_ulogic_vector(31 DOWNTO 0);
 
				--Lane logic variables (reused in conv)
				VARIABLE remaining_u : unsigned(15 DOWNTO 0); --inputs left for this neuron
				VARIABLE remaining_i : INTEGER; --inputs left for this neuron (integer)
				VARIABLE lanes_i : INTEGER; --lanes used for this iteration (max 4)
				VARIABLE lanes_av_in : INTEGER; --input lanes available before crossiing into next word
				VARIABLE lanes_av_wt : INTEGER; --weight lanes available (before crossing into next word)
				VARIABLE lanes_u : unsigned(15 DOWNTO 0); --lanes_i but unsigned
				--lanes help calculate how many inputs and weights for a neuron can be calculated
				VARIABLE next_count : unsigned(15 DOWNTO 0); --number of inputs left to be processed. Helps with deciding if we want to continue with mac state or if we can add
				--Variable prod : signed(63 downto 0); --Intermediate product from dense_requantize
				--the bias
				--also, new value for mac_counter
 
				--Conv variables
				--Variable conv_input_byte_sel : unsigned(1 Downto 0); --byte lane select 0 to 3 for input feature pixel word
				--Variable conv_weight_byte_sel : unsigned(1 Downto 0); --byte lane select 0 to 3 for weight word
				--Reuse lane variables from dense
				VARIABLE conv_cols_left_in_row : INTEGER; --columns left in this row of kernel
				VARIABLE row_i : INTEGER; --Integer version of row index
				VARIABLE col_i : INTEGER; --Integer version of column index
 
					BEGIN
						IF (rising_edge(clk)) THEN
							IF (reset = '1') THEN
								state <= S_IDLE;
								--status_reg <= (others => '0');
								op_code_reg <= (OTHERS => '0');
								base_i_reg <= (OTHERS => '0');
								out_i_reg <= (OTHERS => '0');
								din_reg <= (OTHERS => '0');
								in_i_reg <= (OTHERS => '0');
								softmax_mode_latched <= '0';

								weight_base_reg <= (OTHERS => '0');
								bias_index_reg <= (OTHERS => '0');
								n_inputs_lat <= (OTHERS => '0');
								mac_counter <= (OTHERS => '0');
								accumulator <= (OTHERS => '0');
								bias_val_reg <= (OTHERS => '0');

								dense_lane_count <= (OTHERS => '0');

								pool_out_dim <= (OTHERS => '0');
								pool_row_start_index <= (OTHERS => '0');
								pool_out_row <= (OTHERS => '0');
								pool_out_col <= (OTHERS => '0');
								num00_reg <= (OTHERS => '0');
								num01_reg <= (OTHERS => '0');
								num10_reg <= (OTHERS => '0');
								num11_reg <= (OTHERS => '0');
								r_8_reg <= (OTHERS => '0');

								r_w_reg <= (OTHERS => '0');

								read_index <= (OTHERS => '0');
								read_index_lat <= (OTHERS => '0');
								byte_sel_lat <= (OTHERS => '0');

								pool_dim_we <= '0';

								tensor_A_npu_addr <= (OTHERS => '0');
								tensor_B_npu_addr <= (OTHERS => '0');
								tensor_C_npu_addr <= (OTHERS => '0');
 
								zero_point_lat <= (OTHERS => '0');
								quantized_multiplier_lat <= (OTHERS => '0');
								quantized_multiplier_right_shift_lat <= (OTHERS => '0');
								prod <= (OTHERS => '0');
 
								total_words_in_tensor <= (OTHERS => '0');
								total_int8_elements_in_tensor <= (OTHERS => '0');
								n_filters_lat <= (OTHERS => '0');
								out_filter_stride <= (OTHERS => '0');
								conv_n_out <= (OTHERS => '0');
								conv_out_row <= (OTHERS => '0');
								conv_out_col <= (OTHERS => '0');

							ELSE
								pool_dim_we <= '0';

								CASE state IS
									WHEN S_IDLE => 
										--status_reg(0) <= '0'; --not busy
										IF (start_cmd = '1') THEN
											status_reg(1) <= '0'; --clear done
											state <= S_CAPTURE; --capture parameters
										END IF;

									WHEN S_CAPTURE => 
										--status_reg(0) <= '1'; --The NPU is marked busy once the capture stage begins
										op_code_reg <= ctrl_reg(5 DOWNTO 1);
										din_reg <= unsigned(dim_side_len_8);
										base_i_reg <= unsigned(pool_base_index(15 DOWNTO 0));
										out_i_reg <= unsigned(r_out_index (15 DOWNTO 0));
 
										in_i_reg <= unsigned(word_index_reg(15 DOWNTO 0));
 
										read_index <= (OTHERS => '0');
 
										softmax_mode_latched <= softmax_mode_reg(0); --Latch softmax mode
										weight_base_reg <= unsigned(weight_base_index(15 DOWNTO 0));
										bias_index_reg <= unsigned(bias_index(15 DOWNTO 0));
										n_inputs_lat <= unsigned(n_inputs_reg(15 DOWNTO 0));

										zero_point_lat <= signed(zero_point);
										quantized_multiplier_lat <= signed(quantized_multiplier);
										quantized_multiplier_right_shift_lat <= unsigned(quantized_multiplier_right_shift (7 DOWNTO 0));
 
										conv_filter_index <= (OTHERS => '0');
										n_filters_lat <= unsigned(n_filters_reg(15 DOWNTO 0));
										total_words_to_copy_lat <= unsigned (total_words_to_copy_reg);
										state <= S_PREPARE_PRODUCTS;
 
									WHEN S_PREPARE_PRODUCTS => 
										pool_row_start_index <= base_i_reg;
										pool_out_dim <= shift_right(din_reg, 1);
										total_int8_elements_in_tensor <= resize(din_reg * din_reg, 32); --total int8 elements in input/output tensor
										--In conv: indices to move to start of next input channel = side lengt of input channel * side lengt of input channel (all elements in input channel)
										filter_stride <= resize(n_inputs_lat * 9, 16); --Number of filters * (3x3) = indices to move to next filter. 3x3 = size of filter
										conv_n_out <= din_reg - 2;
										state <= S_OP_CODE_BRANCH;
 
									WHEN S_OP_CODE_BRANCH => 
										--Decode opcode and branch to appropriate datapath
										total_words_in_tensor <= shift_right(total_int8_elements_in_tensor, 2); --total words in input/output tensor
										IF (op_code_reg = OP_NOP) THEN
											state <= S_DONE;
										ELSIF (op_code_reg = OP_MAXPOOL) OR (op_code_reg = OP_AVGPOOL) THEN
											pool_out_row <= (OTHERS => '0');
											pool_out_col <= (OTHERS => '0');
											state <= S_P_READ_REQ;
										ELSIF (op_code_reg = OP_SIGMOID) OR (op_code_reg = OP_RELU) OR (op_code_reg = OP_SOFTMAX) THEN
											state <= S_ACT_READ_REQ;
										ELSIF (op_code_reg = OP_DENSE) THEN
											state <= S_DENSE_INIT;
										ELSIF (op_code_reg = OP_COPY_R_TO_A) THEN
											state <= S_COPY_R_REQ;
										ELSIF (op_code_reg = OP_CONV) THEN
											state <= S_CONV_PREP;
										ELSE
											--status_reg(0) <= '0';
											status_reg(1) <= '1';
											state <= S_IDLE;
										END IF;

										--Copy R to A states-------------------------------------------------
										--Set output_i_reg to 0 in Ada call. out_i_reg is used to index into both, A and R
										--Set words to copy in Ada. Those many words will be copied over from R to A
										--S_COPY_R_REQ, S_COPY_R_WAIT, S_COPY_R_CAP, S_COPY_A_WRITE,
									WHEN S_COPY_R_REQ => 
										tensor_R_npu_addr <= resize(out_i_reg, tensor_R_npu_addr'length); --int32 (word) index
										state <= S_COPY_R_WAIT;
									WHEN S_COPY_R_WAIT => 
										state <= S_COPY_R_CAP;
									WHEN S_COPY_R_CAP => 
										packed_word := tensor_R_npu_rdata;
										in_i_reg <= out_i_reg; --index in A
										r_w_reg <= packed_word;
										state <= S_COPY_A_WRITE;
									WHEN S_COPY_A_WRITE => 
										IF (out_i_reg < total_words_to_copy_lat - 1) THEN
											out_i_reg <= out_i_reg + 1;
											state <= S_COPY_R_REQ;
										ELSE
											state <= S_DONE; 
										END IF;
 
										--Pooling States------------------------------------------------------ 
									WHEN S_P_READ_REQ => 

										current_input_index := compute_pooling_flat_index_2x2(read_index, base_i_reg, din_reg);
										--Request BRAM read for tensor_A word
										word_index := resize(current_input_index(15 DOWNTO 2), word_index'length);
										byte_sel := current_input_index(1 DOWNTO 0);

										tensor_A_npu_addr <= resize(word_index, tensor_A_npu_addr'length);

										--Latch which byte and which slot this read corresponds to
										byte_sel_lat <= byte_sel;
										read_index_lat <= read_index;
										state <= S_P_READ_WAIT;

										--Wait a clock cycle for BRAM read to complete
									WHEN S_P_READ_WAIT => 
										state <= S_P_READ_CAP;

									WHEN S_P_READ_CAP => 
										--Consume BRAM data (available 1 cycle after address request)
										packed_word := tensor_A_npu_rdata;
										sel_byte := Std_ulogic_vector(
										shift_right(unsigned(packed_word), to_integer(byte_sel_lat) * 8)(7 DOWNTO 0)
										);
										--Store into the appropriate register
										CASE read_index_lat IS
											WHEN "00" => num00_reg <= signed(sel_byte);
											WHEN "01" => num01_reg <= signed(sel_byte);
											WHEN "10" => num10_reg <= signed(sel_byte);
											WHEN OTHERS => num11_reg <= signed(sel_byte);
									END CASE;

									--Advance or move to compute
									IF (read_index_lat = "11") THEN
										state <= S_P_CALC;
									ELSE
										read_index <= read_index_lat + 1;
										state <= S_P_READ_REQ;
									END IF;

									WHEN S_P_CALC => 
										--Pooling compute: avg or max across 2x2, result in r_8_reg
										IF (op_code_reg = OP_AVGPOOL) THEN
											r_8_reg <= avgpool4(num00_reg, num01_reg, num10_reg, num11_reg);
										ELSE
											r_8_reg <= maxpool4(num00_reg, num01_reg, num10_reg, num11_reg);
										END IF;
										state <= S_P_WRITE;

									WHEN S_P_WRITE => 
										IF (pool_out_col < pool_out_dim - 1) THEN
											pool_out_col <= pool_out_col + 1; --Move to next column in result
											base_i_reg <= base_i_reg + 2; --Base index + 2 = top-left of next 2x2 window
											out_i_reg <= out_i_reg + 1; 
											read_index <= "00";
											state <= S_P_READ_REQ;
										ELSIF (pool_out_row < pool_out_dim - 1) THEN
											pool_out_col <= (OTHERS => '0'); --Reset output column index
											pool_out_row <= pool_out_row + 1; --Increment output row index
											base_i_reg <= pool_row_start_index + (2 * din_reg);
											pool_row_start_index <= pool_row_start_index + (2 * din_reg);
											out_i_reg <= out_i_reg + 1;
											read_index <= "00";
											state <= S_P_READ_REQ;
										ELSE
											state <= S_DONE;
										END IF;

										--Actiation states--------------------------------------------

									WHEN S_ACT_READ_REQ => 
										--Request tensor_A word
										tensor_A_npu_addr <= resize(in_i_reg, tensor_A_npu_addr'length);
										state <= S_ACT_READ_WAIT;
										--Wait a clock cycle for BRAM read to complete
									WHEN S_ACT_READ_WAIT => 
										state <= S_ACT_CALC;

									WHEN S_ACT_CALC => 

										--Select function based on opcode and softmax mode
										IF (op_code_reg = OP_RELU) THEN
											r_w_reg <= relu_packed_word(tensor_A_npu_rdata);
										ELSIF (op_code_reg = OP_SIGMOID) THEN
											r_w_reg <= sigmoid_packed_word(tensor_A_npu_rdata);
										ELSIF (op_code_reg = OP_SOFTMAX) THEN
											--Determine softmax mode determine for finding exponent (pass 1) or division (pass 2)
											IF (softmax_mode_latched = '0') THEN
												--Exponent phase (Pass 1)
												r_w_reg <= softmax_exponent_packed_word(tensor_A_npu_rdata);
											ELSE
												--Division phase (divide by sum) (Pass 2)
												r_w_reg <= softmax_div_by_sum_packed_word(tensor_A_npu_rdata, unsigned(sum_param_reg(15 DOWNTO 0)));
											END IF;
										END IF;

										state <= S_ACT_WRITE;

									WHEN S_ACT_WRITE => 
										IF (in_i_reg < n_inputs_lat - 1) THEN
											in_i_reg <= in_i_reg + 1;
											state <= S_ACT_READ_REQ;
										ELSE
											state <= S_DONE;
										END IF;

										--Dense states----------------------------------------------------------

									WHEN S_DENSE_INIT => 
										--Request bias word from tensor C
										--tensor_C_npu_rdata is available one cycle after tensor_C_npu_addr is set
										tensor_C_npu_addr <= resize(bias_index_reg, tensor_C_npu_addr'length); --int32 bias (word) index
										state <= S_DENSE_BIAS_WAIT;
									WHEN S_DENSE_BIAS_WAIT => 
										state <= S_DENSE_BIAS_READ;
									WHEN S_DENSE_BIAS_READ => 
										--Bias word is available from BRAM, so we read it
										--byte_sel := bias_index_reg(1 Downto 0);
										packed_word := tensor_C_npu_rdata;
										--bias_val_reg <= extract_byte_from_word(packed_word, to_integer(byte_sel));
										bias_val_reg <= signed(packed_word);
										--Reset dense accumulators/counters after bias has been captured (prep for next neuron)
										accumulator <= (OTHERS => '0');
										mac_counter <= (OTHERS => '0');
										dense_lane_count <= (OTHERS => '0');

										state <= S_DENSE_FETCH;

									WHEN S_DENSE_FETCH => 
										--Fetch a packed group of inputs/weights from A and B for multiplication and accumulation

										--Current element indices
										current_input_index := in_i_reg + mac_counter;
										current_weight_index := weight_base_reg + mac_counter;

										input_word_index := resize(current_input_index(15 DOWNTO 2), input_word_index'length);
										weight_word_index := resize(current_weight_index(15 DOWNTO 2), weight_word_index'length);

										--Request words from tensors A and B
										--tensor_A_npu_rdata and tensor_B_npu_rdata are available in the next cycle
										tensor_A_npu_addr <= resize(input_word_index, tensor_A_npu_addr'length);
										tensor_B_npu_addr <= resize(weight_word_index, tensor_B_npu_addr'length);

										--Byte offset inside the packed word
										input_byte_sel_lat <= to_integer(current_input_index(1 DOWNTO 0));
										weight_byte_sel_lat <= to_integer(current_weight_index(1 DOWNTO 0));

										--Compute how many lanes we can safely process this step
										--Don't want exceed remaining inputs
										--Don't want to cross a 32-bit word boundary
										remaining_u := n_inputs_lat - mac_counter; --remaining inputs to process = total inputs to process - inputs pricessed already
										remaining_i := to_integer(remaining_u);

										lanes_av_in := 4 - to_Integer(current_input_index(1 DOWNTO 0));
										lanes_av_wt := 4 - to_Integer(current_weight_index(1 DOWNTO 0));

										lanes_i := 4; --lanes_i = min(4,remaining_i,lanes_av_in,lanes_av_wt)
										IF (remaining_i < lanes_i) THEN
											lanes_i := remaining_i;
										END IF;
										IF (lanes_av_in < lanes_i) THEN
											lanes_i := lanes_av_in;
										END IF;
										IF (lanes_av_wt < lanes_i) THEN
											lanes_i := lanes_av_wt;
										END IF;

										dense_lane_count <= to_unsigned(lanes_i, dense_lane_count'length);

										state <= S_DENSE_FETCH_WAIT;

									WHEN S_DENSE_FETCH_WAIT => 
										state <= S_DENSE_MAC;

									WHEN S_DENSE_MAC => 
										--Bring selected byte to the right of the word (shift lanes)
										--This part vecomes useful when index + mac_counter is not word aligned. That is, lanes left are < 4. Because we multiply bytes (lanes) starting from the right, we
										--need to put those bytes to the right as well
										input_shift_bits := input_byte_sel_lat * 8;
										weight_shift_bits := weight_byte_sel_lat * 8;

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
											IF (next_count >= n_inputs_lat) THEN
												state <= S_DENSE_BIAS_PRODUCT;
											ELSE
												state <= S_DENSE_FETCH;
											END IF;

									WHEN S_DENSE_BIAS_PRODUCT => 
										--Add bias and saturate to Q0.7 range
										prod <= dense_requantize_product(accumulator, bias_val_reg, quantized_multiplier_lat);
										state <= S_DENSE_REQUANTIZE;
									WHEN S_DENSE_REQUANTIZE => 
										requantize_32 <= dense_requantize(prod, quantized_multiplier_right_shift_lat);
										state <= S_DENSE_BIAS_CLAMP;
									WHEN S_DENSE_BIAS_CLAMP => 
										r_8_reg <= dense_clamp(requantize_32);
										state <= S_DENSE_WRITE;

									WHEN S_DENSE_WRITE => 
										state <= S_DONE;
										--Conv states----------------------------------------------------------
										--In Conv2d, there are multiple kernels within a filter. One kernel for each input channel
										--Output channels = number of filters used
										--Added prep stat because out_filter_stride was causing timing errors
									WHEN S_CONV_PREP => 
										conv_out_row <= (OTHERS => '0');
										conv_out_col <= (OTHERS => '0');
										out_filter_stride <= resize(conv_n_out * conv_n_out, 16);
										conv_pixel_out_base <= (OTHERS => '0');
										state <= S_CONV_INIT;
									WHEN S_CONV_INIT => 
										--Request bias word from tensor C
										--tensor_C_npu_rdata is available one cycle after tensor_C_npu_addr is set
										tensor_C_npu_addr <= resize(bias_index_reg, tensor_C_npu_addr'length) + conv_filter_index; --int32 bias (word) index
 
										filter_weight_base <= weight_base_reg + conv_filter_index * filter_stride; --Filter base = start of all filters for this layer (weight_base_reg) + (filter we are processing)*indices to move to reach to next filter in this layer
										--Save where we want to write the pixel to(out_i_reg is used as the flat index in Tensor R write)
										--Only reset out_i_reg here if we are starting a new filter for a pixel, otherwise out_i_reg holds the correct index as updated in the conv_write state
										IF (conv_filter_index = 0) THEN
											out_i_reg <= conv_pixel_out_base; 
										END IF;
										state <= S_CONV_BIAS_WAIT;
									WHEN S_CONV_BIAS_WAIT => 
										state <= S_CONV_BIAS_READ;
									WHEN S_CONV_BIAS_READ => 
										--Bias word is available from BRAM, so we read it
										--byte_sel := bias_index_reg(1 Downto 0);
										packed_word := tensor_C_npu_rdata;
										--bias_val_reg <= extract_byte_from_word(packed_word, to_integer(byte_sel));
										bias_val_reg <= signed(packed_word);
 
										accumulator <= (OTHERS => '0'); --Reset accumulator for this pixel
										--Reset kernel position counters
										conv_kernel_row <= (OTHERS => '0');
										conv_kernel_col <= (OTHERS => '0');
										conv_input_channel <= (OTHERS => '0');
										--Row pointer starts at the top-left of the input channel feature (set by Ada)
										conv_row_ptr <= in_i_reg;
										--Weight pointer starts at the first weight for this output channel
										--current_weight_index variable is not used because conv_weight_counter is updated across states
										conv_weight_counter <= filter_weight_base; --Weight are stored in a contiguous fashion in B
										state <= S_CONV_FETCH;

									WHEN S_CONV_FETCH => 
										--Fetch a packed group of inputs/weights from A and B for multiplication and accumulation

										--Current element indices
										current_input_index := conv_row_ptr + resize(conv_kernel_col, 16); --Select next column in the row (row entry + col)
										current_weight_index := resize(conv_weight_counter, 16);
										--Request words from tensors A and B
										--tensor_A_npu_rdata and tensor_B_npu_rdata are available in the next cycle
										tensor_A_npu_addr <= resize(current_input_index(15 DOWNTO 2), tensor_A_npu_addr'length);
										tensor_B_npu_addr <= resize(current_weight_index(15 DOWNTO 2), tensor_B_npu_addr'length);
 
										input_byte_sel_lat <= to_integer(current_input_index(1 DOWNTO 0));
										weight_byte_sel_lat <= to_integer(current_weight_index(1 DOWNTO 0));
										--Compute how many lanes we can safely process this step
										--Don't want exit the 3x3 input feature/filter
										--Don't want to cross a 32-bit word boundary
										col_i := to_integer(conv_kernel_col);
										lanes_av_in := 4 - to_integer(current_input_index(1 DOWNTO 0));
										lanes_av_wt := 4 - to_integer(current_weight_index(1 DOWNTO 0));
										conv_cols_left_in_row := 3 - col_i;

										lanes_i := 4; --lanes_i = max(1, min(4, lanes_av_in, lanes_av_wt, conv_cols_left_in_row))
										IF (lanes_av_in < lanes_i) THEN
											lanes_i := lanes_av_in;
										END IF;
										IF (lanes_av_wt < lanes_i) THEN
											lanes_i := lanes_av_wt;
										END IF;
										IF (conv_cols_left_in_row < lanes_i) THEN
											lanes_i := conv_cols_left_in_row; 
										END IF;
										IF (lanes_i < 1) THEN
											lanes_i := 1;
										END IF;
 
										conv_lane_count <= to_unsigned(lanes_i, conv_lane_count'length);

										state <= S_CONV_FETCH_WAIT;

									WHEN S_CONV_FETCH_WAIT => 
										state <= S_CONV_MAC;
 
									WHEN S_CONV_MAC => --We process all the kernels for one input channel first. After we are done with processing one filter (set of kernels), we add the bias. We then proceed to repeat this process for all filters (output channels) for each pixel.
										--We then repeat this process for all pixels
										--Bring selected byte to the right of the word (shift lanes)
										--This part vecomes useful when index + mac_counter is not word aligned. That is, lanes left are < 4. Because we multiply bytes (lanes) starting from the right, we
										--need to put those bytes to the right as well
										input_shift_bits := input_byte_sel_lat * 8;
										weight_shift_bits := weight_byte_sel_lat * 8;

										input_word_shifted := std_ulogic_vector(shift_right(unsigned(tensor_A_npu_rdata), input_shift_bits));
										weight_word_shifted := std_ulogic_vector(shift_right(unsigned(tensor_B_npu_rdata), weight_shift_bits));
 
										--Reusing desne MAC
										accumulator <= dense_mac4(
											accumulator, 
											input_word_shifted, 
											weight_word_shifted, 
											resize(zero_point_lat, 8), 
											to_integer(conv_lane_count)
											);

											--Advance by the number of lanes processed this cycle
											lanes_u := resize(conv_lane_count, lanes_u'length);
											conv_weight_counter <= conv_weight_counter + lanes_u;

											col_i := to_integer(conv_kernel_col);
											row_i := to_integer(conv_kernel_row);
											lanes_i := to_integer(conv_lane_count);

											IF (col_i + lanes_i) < 3 THEN --There are still columns in a rown of 3x3 filter left to be processed
												conv_kernel_col <= to_unsigned(col_i + lanes_i, conv_kernel_col'length); --Update column
												state <= S_CONV_FETCH;
 
											ELSIF (row_i < 2) THEN --there are still rows in the 3x3 filter left to be processed
												conv_kernel_row <= to_unsigned(row_i + 1, conv_kernel_row'length); --Update row
												conv_kernel_col <= "00"; --Reset column to 0
												conv_row_ptr <= conv_row_ptr + resize(din_reg, 16); --Move to the next row
												state <= S_CONV_FETCH;
 
											ELSIF (conv_input_channel < resize(n_inputs_lat - 1, conv_input_channel'length)) THEN --there are more input channels left
												conv_kernel_row <= "00";
												conv_kernel_col <= "00";
												conv_input_channel <= conv_input_channel + 1;
												conv_row_ptr <= resize (in_i_reg
													 + resize(conv_input_channel + 1, 16)
													resize(total_int8_elements_in_tensor(15 DOWNTO 0), 16), 16);
													state <= S_CONV_FETCH;
													--Otherwise requantize the results (including adding the bias)
											ELSE
												state <= S_CONV_REQUANT_PRODUCT;
 
											END IF;

									WHEN S_CONV_REQUANT_PRODUCT => 
										--Add bias and saturate to Q0.7 range
										prod <= dense_requantize_product(accumulator, bias_val_reg, quantized_multiplier_lat);
										state <= S_CONV_REQUANTIZE;
									WHEN S_CONV_REQUANTIZE => 
										requantize_32 <= dense_requantize(prod, quantized_multiplier_right_shift_lat);
										state <= S_CONV_REQUANT_CLAMP;
									WHEN S_CONV_REQUANT_CLAMP => 
										r_8_reg <= dense_clamp(requantize_32);
										state <= S_CONV_WRITE;

									WHEN S_CONV_WRITE => 
										IF (conv_filter_index < (n_filters_lat - 1)) THEN --More filters remain for this pixel
											conv_filter_index <= conv_filter_index + 1;
											out_i_reg <= out_i_reg + out_filter_stride; --Move index to where the pixel for this input and next filter wants to be written to
											state <= S_CONV_INIT;
										ELSE
											--All filters done for this pixel
											conv_filter_index <= (OTHERS => '0');

											IF (conv_out_col < conv_n_out - 1) THEN --If column in result tensor is less tha result tensor dimension (dimension = col count since it is a square), contiue processing for next column
												conv_out_col <= conv_out_col + 1; --Move right within the row
												in_i_reg <= in_i_reg + 1; --in_i_reg is the flat (int8 index) into A. Increment by 1 = next column
												conv_pixel_out_base <= conv_pixel_out_base + 1; --Write to next pixel in output tensor
												state <= S_CONV_INIT;

											ELSIF (conv_out_row < conv_n_out - 1) THEN --Done with all column pixels in this row of result tensor, process next row
												conv_out_row <= conv_out_row + 1; --Wrap to next row
												conv_out_col <= (OTHERS => '0'); --Start at column 0
												in_i_reg <= in_i_reg + 3; --in_i_reg previously pointed at the last valid input column in the in the previous row (side length - 2). Since rows are stored continuosly in memory
												--in_i_reg will skip the last two columns in the input tensor's previous row, and point to the first column of the current (next) row
												conv_pixel_out_base <= conv_pixel_out_base + 1; --Write to next pixel in output tensor
												state <= S_CONV_INIT;
											ELSE
												state <= S_DONE;
											END IF;
										END IF;
									WHEN S_DONE => 
										--status_reg(0) <= '0';
										status_reg(1) <= '1';
										state <= S_IDLE;

								END CASE;
							END IF;
						END IF;
					END PROCESS;
					--When npu_busy='0': WB can read/write tensor windows.
					--When npu_busy='1': NPU owns the tensor memories.
					--Tensor A: WB R/W (when idle) + NPU read (+ NPU in-place write (Softmax EXP))
					PROCESS (clk)
					VARIABLE tensor_offset : NATURAL;
						BEGIN
							IF (rising_edge(clk)) THEN
								IF (reset = '1') THEN
									tensor_A_wb_rdata <= (OTHERS => '0');
									tensor_A_npu_rdata <= (OTHERS => '0');
								ELSE
									IF (npu_busy = '0') THEN
										--WB
										IF (wb_req = '1' AND
										 unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) AND unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE) + to_unsigned(TENSOR_A_BYTES, 32)) THEN
											tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
											IF (tensor_offset < TENSOR_A_WORDS) THEN
												IF (i_wb_we = '1') THEN
													tensor_A_mem(tensor_offset) <= i_wb_data;
												END IF;
												tensor_A_wb_rdata <= tensor_A_mem(tensor_offset);
											ELSE
												tensor_A_wb_rdata <= (OTHERS => '0');
											END IF;
										END IF;

										ELSE
											--NPU port (read)
											IF (to_integer(tensor_A_npu_addr) < TENSOR_A_WORDS) THEN
												tensor_A_npu_rdata <= tensor_A_mem(to_integer(tensor_A_npu_addr));
											ELSE
												tensor_A_npu_rdata <= (OTHERS => '0');
											END IF;

											--NPU in-place write for Softmax EXP (Pass 1)
											IF (((state = S_ACT_WRITE) AND (op_code_reg = OP_SOFTMAX) AND (softmax_mode_latched = '0')) OR state = S_COPY_A_WRITE) THEN
												IF (to_integer(in_i_reg) < TENSOR_A_WORDS) THEN
													tensor_A_mem(to_integer(in_i_reg)) <= r_w_reg;
												END IF;
											END IF;
										END IF;
									END IF;
								END IF;
							END PROCESS;

							--Tensor B: WB R/W (when idle) + NPU read
							PROCESS (clk)
							VARIABLE tensor_offset : NATURAL;
							BEGIN
								IF (rising_edge(clk)) THEN
									IF (reset = '1') THEN
										tensor_B_wb_rdata <= (OTHERS => '0');
										tensor_B_npu_rdata <= (OTHERS => '0');
									ELSE
										IF (npu_busy = '0') THEN
											IF (wb_req = '1' AND
											 unsigned(i_wb_addr) >= unsigned(TENSOR_B_BASE) AND unsigned(i_wb_addr) < unsigned(TENSOR_B_BASE) + to_unsigned(TENSOR_B_BYTES, 32)) THEN
												tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_B_BASE);
												IF (tensor_offset < TENSOR_B_WORDS) THEN
													IF (i_wb_we = '1') THEN
														tensor_B_mem(tensor_offset) <= i_wb_data;
													END IF;
													tensor_B_wb_rdata <= tensor_B_mem(tensor_offset);
												ELSE
													tensor_B_wb_rdata <= (OTHERS => '0');
												END IF;
											END IF;
											ELSE
												IF (to_integer(tensor_B_npu_addr) < TENSOR_B_WORDS) THEN
													tensor_B_npu_rdata <= tensor_B_mem(to_integer(tensor_B_npu_addr));
												ELSE
													tensor_B_npu_rdata <= (OTHERS => '0');
												END IF;
											END IF;
										END IF;
									END IF;
								END PROCESS;

								--Tensor C: WB R/W (when idle) + NPU read
								PROCESS (clk)
								VARIABLE tensor_offset : NATURAL;
								BEGIN
									IF (rising_edge(clk)) THEN
										IF (reset = '1') THEN
											tensor_C_wb_rdata <= (OTHERS => '0');
											tensor_C_npu_rdata <= (OTHERS => '0');
										ELSE
											IF (npu_busy = '0') THEN
												IF (wb_req = '1' AND
												 unsigned(i_wb_addr) >= unsigned(TENSOR_C_BASE) AND unsigned(i_wb_addr) < unsigned(TENSOR_C_BASE) + to_unsigned(TENSOR_C_BYTES, 32)) THEN
													tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_C_BASE);
													IF (tensor_offset < TENSOR_C_WORDS) THEN
														IF (i_wb_we = '1') THEN
															tensor_C_mem(tensor_offset) <= i_wb_data;
														END IF;
														tensor_C_wb_rdata <= tensor_C_mem(tensor_offset);
													ELSE
														tensor_C_wb_rdata <= (OTHERS => '0');
													END IF;
												END IF;
												ELSE
													IF (to_integer(tensor_C_npu_addr) < TENSOR_C_WORDS) THEN
														tensor_C_npu_rdata <= tensor_C_mem(to_integer(tensor_C_npu_addr));
													ELSE
														tensor_C_npu_rdata <= (OTHERS => '0');
													END IF;
												END IF;
											END IF;
										END IF;
									END PROCESS;

									--Tensor R: WB read (when idle) + NPU write
									--NPU writes happen in these states:
									--S_ACT_WRITE : write one packed word at word index in_i_reg (except Softmax EXP pass)
									--S_P_WRITE : write one int8 at element index out_i_reg
									--S_DENSE_WRITE : write one int8 at element index out_i_reg
									--S_CONV_WRITE : write one int8 at element index out_i_reg
									PROCESS (clk)
									VARIABLE tensor_offset : NATURAL;
									VARIABLE w_index : NATURAL;
									VARIABLE byte_sel : NATURAL RANGE 0 TO 3;
									VARIABLE word_tmp : Std_ulogic_vector(31 DOWNTO 0);
									BEGIN
										IF (rising_edge(clk)) THEN
											IF (reset = '1') THEN
												tensor_R_wb_rdata <= (OTHERS => '0');
											ELSE
												IF (npu_busy = '0') THEN
													--WB read port
													IF (wb_req = '1' AND
													 unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) AND unsigned(i_wb_addr) < unsigned(TENSOR_R_BASE) + to_unsigned(TENSOR_R_BYTES, 32)) THEN
														tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_R_BASE);
														IF (tensor_offset < TENSOR_R_WORDS) THEN
															tensor_R_wb_rdata <= tensor_R_mem(tensor_offset);
														ELSE
															tensor_R_wb_rdata <= (OTHERS => '0');
														END IF;
													END IF;

													ELSE
														--NPU write
														IF (state = S_P_WRITE OR state = S_DENSE_WRITE OR state = S_CONV_WRITE) THEN
															--Write a single signed int8 into the packed word at element index out_i_reg
															w_index := to_integer(out_i_reg(15 DOWNTO 2));
															byte_sel := to_integer(out_i_reg(1 DOWNTO 0));
															IF (w_index < TENSOR_R_WORDS) THEN
																word_tmp := tensor_R_mem(w_index);
																CASE byte_sel IS
																	WHEN 0 => word_tmp(7 DOWNTO 0) := Std_ulogic_vector(r_8_reg);
																	WHEN 1 => word_tmp(15 DOWNTO 8) := Std_ulogic_vector(r_8_reg);
																	WHEN 2 => word_tmp(23 DOWNTO 16) := Std_ulogic_vector(r_8_reg);
																	WHEN OTHERS => word_tmp(31 DOWNTO 24) := Std_ulogic_vector(r_8_reg);
																END CASE;
																tensor_R_mem(w_index) <= word_tmp;
															END IF;

														ELSIF (state = S_ACT_WRITE) THEN
															--Softmax EXP is in-place on A, so only write to R for all other activation cases
															IF (NOT (op_code_reg = OP_SOFTMAX AND softmax_mode_latched = '0')) THEN
																IF (to_integer(in_i_reg) < TENSOR_R_WORDS) THEN
																	tensor_R_mem(to_integer(in_i_reg)) <= r_w_reg;
																END IF;
															END IF;
														ELSE
															IF (to_integer(tensor_R_npu_addr) < TENSOR_R_WORDS) THEN
																tensor_R_npu_rdata <= tensor_R_mem(to_integer(tensor_R_npu_addr));
															ELSE
																tensor_R_npu_rdata <= (OTHERS => '0');
															END IF;
														END IF;
													END IF;
												END IF;
											END IF;
										END PROCESS;

END ARCHITECTURE;
