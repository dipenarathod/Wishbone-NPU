library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tensor_operations_basic_arithmetic.all; --import opcodes/constants and packed int8 add/sub
use work.tensor_operations_pooling.all;          --import pooling opcodes & helpers (read/max/avg)
use work.tensor_operations_activation.all;

entity wb_peripheral_top is
  generic (
    BASE_ADDRESS            : std_ulogic_vector(31 downto 0) := x"90000000"; --peripheral base (informational)
    TENSOR_A_BASE           : std_ulogic_vector(31 downto 0) := x"90001000"; --A window base
    TENSOR_B_BASE           : std_ulogic_vector(31 downto 0) := x"90002000"; --B window base
    TENSOR_C_BASE           : std_ulogic_vector(31 downto 0) := x"90003000"; --C window base
    TENSOR_R_BASE           : std_ulogic_vector(31 downto 0) := x"90004000"; --R window base
    CTRL_REG_ADDRESS        : std_ulogic_vector(31 downto 0) := x"90000008"; --[0]=start, [5:1]=opcode
    STATUS_REG_ADDRESS      : std_ulogic_vector(31 downto 0) := x"9000000C"; --[0]=busy, [1]=done (sticky)
    DIM_REG_ADDRESS         : std_ulogic_vector(31 downto 0) := x"90000010"; --N (LSB 8 bits)
    POOL_BASE_INDEX_ADDRESS : std_ulogic_vector(31 downto 0) := x"90000014"; --top-left idx in A
    POOL_OUT_INDEX_ADDRESS  : std_ulogic_vector(31 downto 0) := x"90000018"; --out idx in R
    WORD_INDEX_ADDRESS      : std_ulogic_vector(31 downto 0) := x"9000001C"  --word index for tensor indexing. What word in the word array are we interested in?
  );
  port (
    clk        : in  std_ulogic;                    --system clock
    reset      : in  std_ulogic;                    --synchronous reset
    i_wb_cyc   : in  std_ulogic;                    --Wishbone: cycle valid
    i_wb_stb   : in  std_ulogic;                    --Wishbone: strobe
    i_wb_we    : in  std_ulogic;                    --Wishbone: 1=write, 0=read
    i_wb_addr  : in  std_ulogic_vector(31 downto 0);--Wishbone: address
    i_wb_data  : in  std_ulogic_vector(31 downto 0);--Wishbone: write data
    o_wb_ack   : out std_ulogic;                    --Wishbone: acknowledge
    o_wb_stall : out std_ulogic;                    --Wishbone: stall (always '0')
    o_wb_data  : out std_ulogic_vector(31 downto 0) --Wishbone: read data
  );
end entity;

architecture rtl of wb_peripheral_top is
 
  constant OP_NOP : std_ulogic_vector(4 downto 0) := "11111";
  
  --Wishbone readback data and ack register
  signal data_r : std_ulogic_vector(31 downto 0) := (others => '0');
  signal ack_r  : std_ulogic := '0';

  --Tensor memories (packed 4x int8 per 32-bit word)
  signal tensor_A : tensor_mem_type := (others => (others => '0'));
  signal tensor_B : tensor_mem_type := (others => (others => '0'));
  signal tensor_C : tensor_mem_type := (others => (others => '0'));
  signal tensor_R : tensor_mem_type := (others => (others => '0'));

  --Control and status registers
  signal ctrl_reg       : std_ulogic_vector(31 downto 0) := (others => '0'); --[0]=start, [5:1]=opcode
  signal status_reg     : std_ulogic_vector(31 downto 0) := (others => '0'); --[0]=busy, [1]=done
  signal dim_side_len_8 : std_ulogic_vector(7 downto 0)  := (others => '0'); --N side length
  signal dim_side_len_bus : std_ulogic_vector(31 downto 0) := (others => '0'); --zero-extended N

  --Pooling address parameters
  signal pool_base_index : std_ulogic_vector(31 downto 0) := (others => '0'); --A flat index (top-left)
  signal pool_out_index  : std_ulogic_vector(31 downto 0) := (others => '0'); --R flat index

  --Elementwise word index
  signal word_index_reg  : std_ulogic_vector(31 downto 0) := (others => '0'); --packed word index

  --Start edge detection (one-cycle pulse)
  --ctrlo0 prev is introduced to ensure a new command is not triggered every cycle (when ctrl is set). Look at the process below for the actual logic
  signal start_cmd : std_ulogic := '0';
  signal ctrl0_prev : std_ulogic := '0';

  --Muxed write paths for DIM (allowing bus or internal updates)
  --Will be useful when there is a dedicated pooling/conv unit
  signal bus_dim_we    : std_ulogic := '0';
  signal bus_dim_data  : std_ulogic_vector(7 downto 0) := (others => '0');
  signal pool_dim_we   : std_ulogic := '0';
  signal pool_dim_data : std_ulogic_vector(7 downto 0) := (others => '0');

  --Address helper: translate byte address to word offset within a tensor window
  function get_tensor_offset(addr, base: std_ulogic_vector(31 downto 0)) return natural is
    variable offset: unsigned(31 downto 0);
  begin
    offset := unsigned(addr) - unsigned(base);        --byte delta
    return to_integer(offset(11 downto 2));           --divide by 4 (32-bit words)
  end function;

  --Byte-lane write helper: write signed(7 downto 0) into selected byte of a 32-bit word
  procedure set_int8_into_word(signal R_tensor : inout tensor_mem_type;
                               index : in natural; val : in signed(7 downto 0)) is
    variable w_index    : natural := index / 4;       --which 32-bit word
    variable byte_index : natural := index mod 4;     --which byte within the word
    variable word       : std_ulogic_vector(31 downto 0);
  begin
    word := R_tensor(w_index);                        --read-modify-write the word
    case byte_index is
      when 0 => word(7  downto 0)  := std_ulogic_vector(val);
      when 1 => word(15 downto 8)  := std_ulogic_vector(val);
      when 2 => word(23 downto 16) := std_ulogic_vector(val);
      when others => word(31 downto 24) := std_ulogic_vector(val);
    end case;
    R_tensor(w_index) <= word;                        --write back updated word
  end procedure;

  --Unified FSM state encoding
  type state_t is (
    S_IDLE, S_CAPTURE, S_OP_CODE_BRANCH,
    --pooling path
    --S_P_READ0, S_P_READ1, S_P_READ2, S_P_READ3, S_P_CALC, S_P_WRITE,
    S_P_READ, S_P_CALC, S_P_WRITE,
    S_ACT_READ, S_ACT_CALC, S_ACT_WRITE,
    --elemwise add/sub path
    S_V_READA, S_V_READB, S_V_READC, S_V_CALC, S_V_WRITE,
    S_DONE
  );
  signal state : state_t := S_IDLE;

  --Latched operation parameters for the active command
  signal op_code_reg : std_ulogic_vector(4 downto 0) := (others => '0'); --opcode field
  signal base_i_reg  : unsigned(15 downto 0) := (others => '0');        --pooling base index
  signal out_i_reg   : unsigned(15 downto 0) := (others => '0');        --pooling output index
  signal din_reg     : unsigned(7 downto 0)  := (others => '0');        --N (tensor side length)
  signal word_i_reg  : unsigned(15 downto 0) := (others => '0');        --packed word index

  --Pooling datapath registers (2x2 window and result)
  signal num00_reg, num01_reg, num10_reg, num11_reg : signed(7 downto 0) := (others => '0');
  signal r8_reg  : signed(7 downto 0) := (others => '0');

  --Vector datapath registers for packed word operations
  signal a_w_reg, b_w_reg, c_w_reg, r_w_reg : std_ulogic_vector(31 downto 0) := (others => '0');
 
  signal read_idx : unsigned(1 downto 0) := (others => '0');


begin
  --Simple, non-stalling slave
  o_wb_stall <= '0';
  --Zero-extend N for bus readback
  dim_side_len_bus <= (31 downto 8 => '0') & dim_side_len_8;

  --Generate a one-cycle start pulse when start=1 and not busy
  --Only trigger an operation (start_cmd =1) when ctrl(0) is transitioning to 1 for the first time and the status(0) reg = 0 (not busy)
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        start_cmd <= '0';
        ctrl0_prev  <= '0';
      else
        start_cmd <= '0';
        if (status_reg(0) = '0' and ctrl_reg(0) = '1' and (ctrl0_prev = '0')) then
          start_cmd <= '1';
        end if;
        ctrl0_prev <= ctrl_reg(0);
      end if;
    end if;
  end process;

  --DIM (N) register with two write sources: pooling path or bus write
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        dim_side_len_8 <= x"1C"; --default N=28. TODO: Use N=50 in the future
      else
        if pool_dim_we = '1' then
          dim_side_len_8 <= pool_dim_data; --TODO: When there is a dedicated pooling unit with variable window sizes
        elsif bus_dim_we = '1' then
          dim_side_len_8 <= bus_dim_data;  --bus write-update
        end if;
      end if;
    end if;
  end process;

  --Unified FSM handling pooling and vector operations
  process(clk)
    variable elem_index  : unsigned(15 downto 0);                 --flat index into A/R
    variable word_idx    : natural;                                --32-bit word index
    variable byte_sel    : integer;                                --byte lane select 0..3
    variable packed_word : std_ulogic_vector(31 downto 0);         --fetched 32-bit word
    variable sel_byte    : std_ulogic_vector(7 downto 0);          --selected byte from word
  begin
    if rising_edge(clk) then
      if reset = '1' then
        state <= S_IDLE;
        status_reg <= (others => '0');
        op_code_reg <= (others => '0');
        base_i_reg <= (others => '0');
        out_i_reg  <= (others => '0');
        din_reg    <= (others => '0');
        word_i_reg <= (others => '0');
        r8_reg     <= (others => '0');
        a_w_reg <= (others => '0'); 
        b_w_reg <= (others => '0');
        c_w_reg <= (others => '0'); 
        r_w_reg <= (others => '0');
        pool_dim_we <= '0';
      else
        pool_dim_we <= '0';

        case state is
          when S_IDLE =>
            status_reg(0) <= '0';                --not busy
            if start_cmd = '1' then
              status_reg(1) <= '0';             --clear done
              state <= S_CAPTURE;               --capture parameters
            end if;
        when S_CAPTURE =>
          status_reg(0) <= '1'; --The NPU is marked busy once the capture stage begins. The capture stage sets up everything (all registers) for the following states
          op_code_reg <= ctrl_reg(5 downto 1);
          din_reg     <= unsigned(dim_side_len_8);
          base_i_reg  <= unsigned(pool_base_index(15 downto 0));
          out_i_reg   <= unsigned(pool_out_index(15 downto 0));
          word_i_reg  <= unsigned(word_index_reg(15 downto 0));
          read_idx    <= (others => '0');  --start 2x2 sweep at top-left
          state <= S_OP_CODE_BRANCH;
       when S_OP_CODE_BRANCH => --If-else
          if (op_code_reg = OP_NOP) then
            state <= S_DONE;
          elsif (op_code_reg = OP_MAXPOOL) or (op_code_reg = OP_AVGPOOL) then
            state <= S_P_READ;
          elsif(op_code_reg = OP_SIGMOID) or (op_code_reg = OP_RELU) then
            state <= S_ACT_READ;
          elsif (op_code_reg = OP_ADD) or (op_code_reg = OP_SUB) then
            state <= S_V_READA;
          else
            status_reg(0) <= '0'; status_reg(1) <= '1'; state <= S_IDLE;
          end if;
       when S_P_READ =>
              --Compute flat element index for the current 2x2 position
              case read_idx is
                when "00" => elem_index := base_i_reg;                                                --(0,0)
                when "01" => elem_index := base_i_reg + 1;                                            --(0,1)
                when "10" => elem_index := base_i_reg + resize(din_reg, elem_index'length);           --(1,0)
                when others => elem_index := base_i_reg + resize(din_reg, elem_index'length) + 1;     --(1,1)
              end case;
            
              --Decode packed word and byte lane
              --Word index doesn't care for the byte offset. We just need the word number in the word array (tensor)                                                   
              --The last two bits of elem_index tell what byte in the word we are looking for (00, 01, 10, 11) or (0, 1, 2, 3)                                                   
              word_idx := to_integer(elem_index(15 downto 2));
              byte_sel := to_integer(elem_index(1 downto 0));
              packed_word := tensor_A(word_idx);
              case byte_sel is
                when 0 => sel_byte := packed_word(7  downto 0);
                when 1 => sel_byte := packed_word(15 downto 8);
                when 2 => sel_byte := packed_word(23 downto 16);
                when others => sel_byte := packed_word(31 downto 24);
              end case;
            
              --Store into the appropriate register
              case read_idx is
                when "00" => num00_reg <= signed(sel_byte);
                when "01" => num01_reg <= signed(sel_byte);
                when "10" => num10_reg <= signed(sel_byte);
                when others => num11_reg <= signed(sel_byte);
              end case;
              
              --Advance or move to compute
              if read_idx = "11" then
                state <= S_P_CALC;
              else
                read_idx <= read_idx + 1;
                state <= S_P_READ;
              end if;
            
          --Pooling compute: avg or max across 2x2, result in r8_reg
          when S_P_CALC =>
            if op_code_reg = OP_AVGPOOL then
              r8_reg <= avgpool4(num00_reg, num01_reg, num10_reg, num11_reg);
            else
              r8_reg <= maxpool4(num00_reg, num01_reg, num10_reg, num11_reg);
            end if;
            state <= S_P_WRITE;

          --Pooling writeback: write single int8 into R at out_i_reg
          when S_P_WRITE =>
            set_int8_into_word(tensor_R, to_integer(out_i_reg), r8_reg);
            state <= S_DONE;

          --Sigmoid states
          when S_ACT_READ =>
            a_w_reg <= tensor_A(to_integer(word_i_reg));  --read A[word] once
            state   <= S_ACT_CALC;
            
          when S_ACT_CALC =>
            if op_code_reg = OP_RELU then
              r_w_reg <= relu_packed_word(a_w_reg);
            else
              r_w_reg <= sigmoid_packed_word(a_w_reg);      --apply sigmoid to word
            end if;
            state   <= S_ACT_WRITE;
            
          when S_ACT_WRITE =>
            tensor_R(to_integer(word_i_reg)) <= r_w_reg;  --write result to R[word]
            state <= S_DONE;
          
          --Vector path: read packed A/B/C words at word_i_reg
          --Not used because they were only for testing.
          when S_V_READA =>
            a_w_reg <= tensor_A(to_integer(word_i_reg));
            state <= S_V_READB;

          when S_V_READB =>
            b_w_reg <= tensor_B(to_integer(word_i_reg));
            state <= S_V_READC;

          when S_V_READC =>
            c_w_reg <= tensor_C(to_integer(word_i_reg));
            state <= S_V_CALC;

          --Vector calc: lane-wise add or sub using imported functions
          when S_V_CALC =>
            if op_code_reg = OP_ADD then
              r_w_reg <= add_packed_int8(a_w_reg, b_w_reg, c_w_reg);
            else
              r_w_reg <= sub_packed_int8(a_w_reg, b_w_reg, c_w_reg);
            end if;
            state <= S_V_WRITE;

          --Vector writeback: write packed result word to R
          when S_V_WRITE =>
            tensor_R(to_integer(word_i_reg)) <= r_w_reg;
            state <= S_DONE;

          --Calculation completedd: clear busy, set done, return to IDLE
          when S_DONE =>
            status_reg(0) <= '0';
            status_reg(1) <= '1';
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

  --Wishbone write path: decode addresses, update regs, and tensor windows
  --Read/write logic is very similar. 
  process(clk)
    variable tensor_offset: natural; --word offset inside a tensor window
  begin
    if rising_edge(clk) then
      if reset = '1' then
        ctrl_reg <= (others => '0');
        pool_base_index <= (others => '0');
        pool_out_index  <= (others => '0');
        word_index_reg  <= (others => '0');
        bus_dim_we <= '0';
        bus_dim_data <= (others => '0');
      elsif (i_wb_cyc = '1' and i_wb_stb = '1' and i_wb_we = '1') then
        bus_dim_we <= '0'; --default, set only when DIM is written

        if (i_wb_addr = CTRL_REG_ADDRESS) then
          ctrl_reg <= i_wb_data;
        elsif (i_wb_addr = DIM_REG_ADDRESS) then
          bus_dim_we   <= '1';
          bus_dim_data <= i_wb_data(7 downto 0);
        elsif (i_wb_addr = POOL_BASE_INDEX_ADDRESS) then
          pool_base_index <= i_wb_data;
        elsif (i_wb_addr = POOL_OUT_INDEX_ADDRESS) then
          pool_out_index <= i_wb_data;
        elsif (i_wb_addr = WORD_INDEX_ADDRESS) then
          word_index_reg <= i_wb_data;

        --Tensor A window write
        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) and
               unsigned(i_wb_addr) <  unsigned(TENSOR_A_BASE) + (TENSOR_WORDS*4)) then
          tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
          if tensor_offset < TENSOR_WORDS then
            tensor_A(tensor_offset) <= i_wb_data;
          end if;

        --Tensor B window write
        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_B_BASE) and
               unsigned(i_wb_addr) <  unsigned(TENSOR_B_BASE) + (TENSOR_WORDS*4)) then
          tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_B_BASE);
          if tensor_offset < TENSOR_WORDS then
            tensor_B(tensor_offset) <= i_wb_data;
          end if;

        --Tensor C window write
        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_C_BASE) and
               unsigned(i_wb_addr) <  unsigned(TENSOR_C_BASE) + (TENSOR_WORDS*4)) then
          tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_C_BASE);
          if tensor_offset < TENSOR_WORDS then
            tensor_C(tensor_offset) <= i_wb_data;
          end if;
        end if;
      end if;
    end if;
  end process;

  --Wishbone read path: decode and mux back regs and tensor windows
  process(clk)
    variable tensor_offset: natural; --word offset inside a tensor window
  begin
    if rising_edge(clk) then
      if reset = '1' then
        data_r <= (others => '0');
      elsif (i_wb_cyc = '1' and i_wb_stb = '1' and i_wb_we = '0') then
        if (i_wb_addr = CTRL_REG_ADDRESS) then
          data_r <= ctrl_reg;
        elsif (i_wb_addr = STATUS_REG_ADDRESS) then
          data_r <= status_reg;
        elsif (i_wb_addr = DIM_REG_ADDRESS) then
          data_r <= dim_side_len_bus;
        elsif (i_wb_addr = POOL_BASE_INDEX_ADDRESS) then
          data_r <= pool_base_index;
        elsif (i_wb_addr = POOL_OUT_INDEX_ADDRESS) then
          data_r <= pool_out_index;

        --Tensor A window read
        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) and
               unsigned(i_wb_addr) <  unsigned(TENSOR_A_BASE) + (TENSOR_WORDS*4)) then
          tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
          if tensor_offset < TENSOR_WORDS then
            data_r <= tensor_A(tensor_offset);
          else
            data_r <= (others => '0');
          end if;

        --Tensor B/C window reads (similar to Tensor A)
        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_B_BASE) and
               unsigned(i_wb_addr) <  unsigned(TENSOR_B_BASE) + (TENSOR_WORDS*4)) then
          tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_B_BASE);
          if tensor_offset < TENSOR_WORDS then
            data_r <= tensor_B(tensor_offset);
          else
            data_r <= (others => '0');
          end if;
        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_C_BASE) and
               unsigned(i_wb_addr) <  unsigned(TENSOR_C_BASE) + (TENSOR_WORDS*4)) then
          tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_C_BASE);
          if tensor_offset < TENSOR_WORDS then
            data_r <= tensor_C(tensor_offset);
          else
            data_r <= (others => '0');
          end if;

        --Tensor R window read
        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) and
               unsigned(i_wb_addr) <  unsigned(TENSOR_R_BASE) + (TENSOR_WORDS*4)) then
          tensor_offset := get_tensor_offset(i_wb_addr, TENSOR_R_BASE);
          if tensor_offset < TENSOR_WORDS then
            data_r <= tensor_R(tensor_offset);
          else
            data_r <= (others => '0');
          end if;

        else
          data_r <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  --Wishbone ACK generation: assert for valid mapped registers (and memory regions) addresses during active bus cycles
  process(clk)
    variable is_valid: std_ulogic; --address decode result
  begin
    if rising_edge(clk) then
      if reset = '1' then
        ack_r <= '0';
      else
        is_valid := '0';
        if (i_wb_addr = CTRL_REG_ADDRESS or
            i_wb_addr = STATUS_REG_ADDRESS or
            i_wb_addr = DIM_REG_ADDRESS or
            i_wb_addr = POOL_BASE_INDEX_ADDRESS or
            i_wb_addr = POOL_OUT_INDEX_ADDRESS or
            i_wb_addr = WORD_INDEX_ADDRESS or
            (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) and unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE) + (TENSOR_WORDS*4)) or
            (unsigned(i_wb_addr) >= unsigned(TENSOR_B_BASE) and unsigned(i_wb_addr) < unsigned(TENSOR_B_BASE) + (TENSOR_WORDS*4)) or
            (unsigned(i_wb_addr) >= unsigned(TENSOR_C_BASE) and unsigned(i_wb_addr) < unsigned(TENSOR_C_BASE) + (TENSOR_WORDS*4)) or
            (unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) and unsigned(i_wb_addr) < unsigned(TENSOR_R_BASE) + (TENSOR_WORDS*4))) then
          is_valid := '1';
        end if;

        if (i_wb_cyc = '1' and i_wb_stb = '1' and is_valid = '1') then
          ack_r <= '1';
        else
          ack_r <= '0';
        end if;
      end if;
    end if;
  end process;

  --Drive Wishbone outputs
  o_wb_ack  <= ack_r;
  o_wb_data <= data_r;
end architecture;
