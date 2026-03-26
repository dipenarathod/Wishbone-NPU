library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tensor_operations_basic_arithmetic.all; --MAX_DIM cap, TENSOR_WORDS, and tensor_mem_type layout (4x int8 per 32-bit word)
use work.tensor_operations_pooling.all;          --Pure helpers: read_int_in_word(), maxpool4(), avgpool4() and OP_* opcodes


--Only tensors now: A (source) and R (destination), each packed as 4 int8 per 32-bit word.
--POOL_BASE_INDEX: flat element index in A for the top-left (num00) of the 2x2 window.
--POOL_OUT_INDEX: flat element index in R where the pooled result is stored.
--On a START pulse, performs exactly one 2x2 pooling operation (MAX or AVG) and returns DONE; software iterates windows.
entity wb_peripheral_top is
  generic (
    BASE_ADDRESS: std_ulogic_vector(31 downto 0):= x"90000000"; --Peripheral base (optional; not used in decode here)
    TENSOR_A_BASE: std_ulogic_vector(31 downto 0):= x"90001000"; --Word-addressable window for Tensor A writes/reads
    TENSOR_R_BASE: std_ulogic_vector(31 downto 0):= x"90004000"; --Word-addressable window for Tensor R reads
    CTRL_REG_ADDRESS: std_ulogic_vector(31 downto 0):= x"90000008"; --CTRL: [0]=start, [5:1]=opcode (OP_MAXPOOL|OP_AVGPOOL)
    STATUS_REG_ADDRESS: std_ulogic_vector(31 downto 0):= x"9000000C"; --STATUS: [0]=busy, [1]=done (sticky one-shot behavior)
    DIM_REG_ADDRESS: std_ulogic_vector(31 downto 0):= x"90000010"; --DIM: input side length N (only bits [7:0] used)
    POOL_BASE_INDEX_ADDRESS: std_ulogic_vector(31 downto 0):= x"90000014"; --Top-left element index in A for the 2x2 window
    POOL_OUT_INDEX_ADDRESS: std_ulogic_vector(31 downto 0):= x"90000018"  --Destination flat element index in R for the result
  );
  port (
    clk        : in  std_ulogic;
    reset      : in  std_ulogic;

    --Wishbone interface
    i_wb_cyc   : in  std_ulogic;
    i_wb_stb   : in  std_ulogic;
    i_wb_we    : in  std_ulogic;
    i_wb_addr  : in  std_ulogic_vector(31 downto 0);
    i_wb_data  : in  std_ulogic_vector(31 downto 0);
    o_wb_ack   : out std_ulogic;
    o_wb_stall : out std_ulogic;
    o_wb_data  : out std_ulogic_vector(31 downto 0)
  );
end entity;

architecture rtl of wb_peripheral_top is
  --Wishbone interface signals
  signal data_r   : std_ulogic_vector(31 downto 0) := (others => '0');
  signal ack_r    : std_ulogic := '0';

  --Tensor storage (28x28 max, int8)
  --constant MAX_DIM : natural := 28;
  --constant TENSOR_WORDS : natural := 196;  --(28*28)/4
  --type tensor_mem_type is array (0 to TENSOR_WORDS-1) of std_ulogic_vector(31 downto 0);
  signal tensor_A: tensor_mem_type:= (others => (others => '0')); --Source tensor A (write/read via bus)
  signal tensor_R: tensor_mem_type:= (others => (others => '0')); --Result tensor R (write by hardware, read via bus)

  signal ctrl_reg    : std_ulogic_vector(31 downto 0):= (others => '0');
  --ctrl_reg[0]: start
  --ctrl_reg[5:1]: opcode
  signal status_reg  : std_ulogic_vector(31 downto 0):= (others => '0');
  --status_reg[0]: busy flag
  --status_reg[1]: done flag


  signal dim_side_len_8   : std_ulogic_vector(7 downto 0):= (others => '0'); --Side with= N stored in 8-bits for faster computations
  signal dim_side_len_bus   : std_ulogic_vector(31 downto 0):= (others => '0'); --Side width = N in 32-bit form for easier reading/writing from addresses

  --Software-supplied indices for one pooled output:
  --pool_base_index: flat element index in A for num00 (top-left of 2x2 window).
  --pool_out_index: flat element index in R where the pooled result is written.
  signal pool_base_index: std_ulogic_vector(31 downto 0):= (others => '0');
  signal pool_out_index: std_ulogic_vector(31 downto 0):= (others => '0');

  --Capture the start signal once to prevent multiple re-trigger
  signal start_cmd   : std_ulogic:= '0';

  
  signal bus_dim_we: std_ulogic:= '0';--Enable the wishbone bus to write to dim registe
  signal bus_dim_data: std_ulogic_vector(7 downto 0):= (others => '0');--Data for dim register from the bus
  signal pool_dim_we: std_ulogic:= '0';--Enable the pooling layer to write to dim register
  signal pool_dim_data: std_ulogic_vector(7 downto 0):= (others => '0');--Data for dim register from the pooling layer. This shows the new tensor dimensions.

  --Address decoder helper
  function get_tensor_offset(addr: std_ulogic_vector(31 downto 0); 
                             base: std_ulogic_vector(31 downto 0)) 
    return natural is
    variable offset: unsigned (31 downto 0); --Offset is a 32 bit unsigned number
  begin
    offset:= unsigned(addr)- unsigned(base);
    return to_integer(offset(11 downto 2));  --Each address is used to address a byte
                                             --0x9000_0000 points to byte A
                                             --0x9000_0001 points ot byte B
                                             --0x9000_0002 points to byte C
                                             --0x9000_0003 points to byte D\
                                             --the above four address form a 32-bit word
                                             --Subtracting two address gives the number of bytes
                                             --The last two bits (1 and 0) do not matter as they are useful in specifying the byte within the word.
                                             --Dividing the subtraction result by 4 gives the number 0f words. Number of bytes = 4 * number of words
  end function;

  --Store a single signed int8 into a 32-bit word in tensor_R at the element index
  procedure set_int8_into_word(signal R_tensor: inout tensor_mem_type;
                   index       : in    natural;
                   val       : in    signed(7 downto 0)) is
    variable w_index: natural:= index / 4;                 --Word index containing this element
    variable byte_index: natural:= index mod 4;                  --Byte index withing word
    variable word: std_ulogic_vector(31 downto 0);
  begin
    word:= R_tensor(w_index);
    case byte_index is
      when 0 => word(7  downto 0):= std_ulogic_vector(val);       
      when 1 => word(15 downto 8):= std_ulogic_vector(val);       
      when 2 => word(23 downto 16):= std_ulogic_vector(val);       
      when others => word(31 downto 24):= std_ulogic_vector(val);
    end case;
    R_tensor(w_index)<= word;
  end procedure;

begin
  --Bus is always ready; no wait-state insertion for this compact peripheral.
  o_wb_stall<= '0';

  --Zero-extend the internal 8-bit DIM to 32 bits for software reads and portability.
  dim_side_len_bus <= (31 downto 8 => '0') & dim_side_len_8;

  --Start edge detector
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        start_cmd<= '0';
      else
        if (status_reg(0) = '0' and ctrl_reg(0) = '1') then --Idle and start requested
          start_cmd<= '1';
        else
          start_cmd<= '0';
        end if;
      end if;
    end if;
  end process;

  --Ensure dim_len is updated by only one driver (otherwise there are problems during implemetation
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        dim_side_len_8<= x"1C"; --Default to 28 at reset (resource-conscious image size)
      else
        if pool_dim_we = '1' then
          dim_side_len_8<= pool_dim_data;
        elsif bus_dim_we = '1' then
          dim_side_len_8<= bus_dim_data;
        end if;
      end if;
    end if;
  end process;

  --FSM
  --Remove addition and subtraction
  process(clk)
    variable op_code: std_ulogic_vector(4 downto 0); --Decoded opcode (CTRL[5:1])
    variable base_i: natural;                       --Flat base index in A for num00
    variable din: natural;                       --Input side length N
    variable num00,num01,num10,num11: signed(7 downto 0); --Window samples as signed int8
    variable r: signed(7 downto 0);            --Computed pooled result (int8)
    variable out_i: natural;                       --Flat destination index in R
  begin
    if rising_edge(clk) then
      if reset = '1' then
        status_reg  <= (others => '0'); --Clear busy/done on reset
        pool_dim_we <= '0';
      else
        pool_dim_we<= '0';              --Default: no automatic DIM change

        if start_cmd = '1' then
          --Enter "busy" for the single-cycle op and clear "done"
          status_reg(0)<= '1'; --busy=1
          status_reg(1)<= '0'; --done=0

          --Parameter capture from registers
          op_code:= ctrl_reg(5 downto 1);
          base_i:= to_integer(unsigned(pool_base_index));
          din   := to_integer(unsigned(dim_side_len_8));
          out_i := to_integer(unsigned(pool_out_index));

          --Fetch the 2x2 window top-lefted at base_i:
          --num00 = A[base_i], num01 = A[base_i+1], num10 = A[base_i+N], num11 = A[base_i+N+1]
          --read_int_in_word() interprets packed layout and returns signed int8.
          num00:= read_int_in_word(tensor_A, base_i);
          num01:= read_int_in_word(tensor_A, base_i+1);
          num10:= read_int_in_word(tensor_A, base_i+din);
          num11:= read_int_in_word(tensor_A, base_i+din+1);

          --Select pooling mode via opcode and compute result using pure functions:
          if op_code = OP_AVGPOOL then
            r:= avgpool4(num00, num01, num10, num11);  --Average pooling
          else
            r:= maxpool4(num00, num01, num10, num11);  --Max pooling
          end if;

          --Store the pooled int8 into Tensor R at the designated output index
          set_int8_into_word(tensor_R, out_i, r);

          --clear busy and flag done
          status_reg(0)<= '0'; --busy=0
          status_reg(1)<= '1'; --done=1
        end if;
      end if;
    end if;
  end process;

  --Write over Wishbone (from NEORV32 to Peripheral)
  process(clk)
    variable tensor_offset: natural; --Word index into tensor window for writes
  begin
    if rising_edge(clk) then
      if reset = '1' then
        ctrl_reg      <= (others => '0');
        pool_base_index <= (others => '0');
        pool_out_index  <= (others => '0');
        bus_dim_we    <= '0';
        bus_dim_data  <= (others => '0');
      elsif (i_wb_cyc = '1' and i_wb_stb = '1' and i_wb_we = '1') then
        bus_dim_we<= '0'; --Default low; asserted only for DIM writes

        if (i_wb_addr = CTRL_REG_ADDRESS) then
          ctrl_reg<= i_wb_data;                       --Load START/opcode

        elsif (i_wb_addr = DIM_REG_ADDRESS) then
          bus_dim_we  <= '1';                         --Request DIM update
          bus_dim_data<= i_wb_data(7 downto 0);       --Only LSB 8 bits are used

        elsif (i_wb_addr = POOL_BASE_INDEX_ADDRESS) then
          pool_base_index<= i_wb_data;                  --Set base index in A

        elsif (i_wb_addr = POOL_OUT_INDEX_ADDRESS) then
          pool_out_index<= i_wb_data;                   --Set destination index in R

        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) and
               unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE)+(TENSOR_WORDS*4)) then
          --Word-aligned write to Tensor A window
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
          if tensor_offset < TENSOR_WORDS then
            tensor_A(tensor_offset)<= i_wb_data;
          end if;
        end if;
      end if;
    end if;
  end process;

  --Read over Wishbone
  process(clk)
    variable tensor_offset: natural; --Word index into tensor window for reads
  begin
    if rising_edge(clk) then
      if reset = '1' then
        data_r<= (others => '0');
      elsif (i_wb_cyc = '1' and i_wb_stb = '1' and i_wb_we = '0') then
        if (i_wb_addr = CTRL_REG_ADDRESS) then
          data_r<= ctrl_reg;
        elsif (i_wb_addr = STATUS_REG_ADDRESS) then
          data_r<= status_reg;
        elsif (i_wb_addr = DIM_REG_ADDRESS) then
          data_r<= dim_side_len_bus;                          --Zero-extended 8-bit DIM
        elsif (i_wb_addr = POOL_BASE_INDEX_ADDRESS) then
          data_r<= pool_base_index;
        elsif (i_wb_addr = POOL_OUT_INDEX_ADDRESS) then
          data_r<= pool_out_index;

        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) and
               unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE)+(TENSOR_WORDS*4)) then
          --Word-aligned read from Tensor A window
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
          if tensor_offset < TENSOR_WORDS then
            data_r<= tensor_A(tensor_offset);
          else
            data_r<= (others => '0');
          end if;

        elsif (unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) and
               unsigned(i_wb_addr) < unsigned(TENSOR_R_BASE)+(TENSOR_WORDS*4)) then
          --Word-aligned read from Tensor R window
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_R_BASE);
          if tensor_offset < TENSOR_WORDS then
            data_r<= tensor_R(tensor_offset);
          else
            data_r<= (others => '0');
          end if;

        else
          data_r<= (others => '0');                    --Unmapped: return zeros
        end if;
      end if;
    end if;
  end process;

  --Wishbone acknowledge
  process(clk)
    variable is_valid: std_ulogic;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        ack_r<= '0';
      else
        is_valid:= '0';
        if (i_wb_addr = CTRL_REG_ADDRESS or
            i_wb_addr = STATUS_REG_ADDRESS or
            i_wb_addr = DIM_REG_ADDRESS or
            i_wb_addr = POOL_BASE_INDEX_ADDRESS or
            i_wb_addr = POOL_OUT_INDEX_ADDRESS or
            (unsigned(i_wb_addr) >= unsigned(TENSOR_A_BASE) and unsigned(i_wb_addr) < unsigned(TENSOR_A_BASE)+(TENSOR_WORDS*4)) or
            (unsigned(i_wb_addr) >= unsigned(TENSOR_R_BASE) and unsigned(i_wb_addr) < unsigned(TENSOR_R_BASE)+(TENSOR_WORDS*4))) then
          is_valid:= '1';
        end if;

        if (i_wb_cyc = '1' and i_wb_stb = '1' and is_valid = '1') then
          ack_r<= '1';
        else
          ack_r<= '0';
        end if;
      end if;
    end if;
  end process;

  o_wb_ack<= ack_r;
  o_wb_data<= data_r;
end architecture;
