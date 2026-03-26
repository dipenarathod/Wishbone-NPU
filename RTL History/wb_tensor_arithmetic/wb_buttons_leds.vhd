library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tensor_operations_basic_arithmetic.all;

entity wb_peripheral_top is
  generic (
    BASE_ADDRESS   : std_ulogic_vector(31 downto 0):= x"90000000";
    --LED_ADDRESS    : std_ulogic_vector(31 downto 0):= x"90000000";
    --BUTTON_ADDRESS : std_ulogic_vector(31 downto 0):= x"90000004";
    --Tensor memory addresses
    TENSOR_A_BASE: std_ulogic_vector(31 downto 0):= x"90001000";
    TENSOR_B_BASE: std_ulogic_vector(31 downto 0):= x"90002000";
    TENSOR_C_BASE: std_ulogic_vector(31 downto 0):= x"90003000";
    TENSOR_R_BASE: std_ulogic_vector(31 downto 0):= x"90004000";
    --Control and status registers
    CTRL_REG_ADDRESS: std_ulogic_vector(31 downto 0):= x"90000008";
    STATUS_REG_ADDRESS: std_ulogic_vector(31 downto 0):= x"9000000C";
    DIM_REG_ADDRESS: std_ulogic_vector(31 downto 0):= x"90000010"
  );
  port (
    clk       : in  std_ulogic;
    reset     : in  std_ulogic;

    -- Wishbone interface
    i_wb_cyc  : in  std_ulogic;
    i_wb_stb  : in  std_ulogic;
    i_wb_we   : in  std_ulogic;
    i_wb_addr : in  std_ulogic_vector(31 downto 0);
    i_wb_data : in  std_ulogic_vector(31 downto 0);
    o_wb_ack  : out std_ulogic;
    o_wb_stall: out std_ulogic;
    o_wb_data : out std_ulogic_vector(31 downto 0)

    -- I/O
    --buttons   : in  std_ulogic_vector(2 downto 0);
    --leds      : out std_ulogic_vector(7 downto 0)
  );
end entity;

architecture rtl of wb_peripheral_top is
  --Original signals
  --signal leds_r   : std_ulogic_vector(7 downto 0):= (others => '0');
  signal data_r   : std_ulogic_vector(31 downto 0):= (others => '0');
  signal ack_r    : std_ulogic:= '0';

  --Tensor storage (50x50 max, int8)
  --Each tensor contains at max 2500 elements of 8 bits each
  --4 int8 values can be stored into each 32-bit word
  --Total words needed per tensor: 2500/4 = 625 words
  --TODO: THE FOLLOWING TWO LINES NEED TO BE MODIFIED WHEN PARAMETERIZING THE FUNCTION TO SUPPORT DIFFERENT SIZE TENSORS
  constant MAX_DIM: natural:= 50;
  constant TENSOR_WORDS: natural:= 625;  --(50*50)/4

  type tensor_mem_type is array (0 to TENSOR_WORDS-1) of std_ulogic_vector(31 downto 0);
  --tensor_mem_type is an array of 625 elements, where each element can store 32 bits
  --It is the equivalent of 625 32-bit words = int8 50x50 tensor
  signal tensor_A: tensor_mem_type:= (others => (others => '0')); --tensor operand 1 = tensor A
  --(others => (others => '0')) sets all the elements in the 2D structure to 0
  signal tensor_B: tensor_mem_type:= (others => (others => '0')); --tensor operand 2 = tensor B
  signal tensor_C: tensor_mem_type:= (others => (others => '0')); --tensor operand 3 = tensor C
  signal tensor_R: tensor_mem_type:= (others => (others => '0')); --result tensor

  --Control and status registers
  signal ctrl_reg: std_ulogic_vector(31 downto 0):= (others => '0');    --bit[0] for start
                                                                        --bit[5:1] for commands -> 2^5 = 32 commands
                                                                        --'00000' for Addition
                                                                        --'00001' for Subtraction
                                                                        --'00010' for GEMM
                                                                        --(and so on)
--  constant OP_ADD: std_ulogic_vector(4 downto 0):= "00000";  --R = A + B + C
--  constant OP_SUB: std_ulogic_vector(4 downto 0):= "00001";  --R = A - B - C
--  --TODO: Add similar codes in the future                                                                  
  signal status_reg: std_ulogic_vector(31 downto 0):= (others => '0'); --bit[0] for busy. bit[1] for done. TODO: Combine the two into 1?
  signal dim_reg: std_ulogic_vector(31 downto 0):= (others => '0');

  --Addition operation state machine
  type state_type is (IDLE, PERFORMING_OPERATION, DONE);--Basically an enum. add_state_type can idle, adding, or done with the computation
  signal state: state_type:= IDLE; --Start state is idle
  signal index: natural range 0 to TENSOR_WORDS-1:= 0; --Number of words left to process in a tensor calculation
                                                         --Equivalent to a i in for(int i=0; i<TENSOR_WORDS;i++)
                                                         --Use natural range because we do not want negative numbers in range
                                                         --We want non-negative integers
  --Capture the start signal once to prevent multiple re-trigger
  --We do not want to restart the computation we have already started. A latch of sorts
  signal start_cmd: std_ulogic:= '0';

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
                                             --Dividing the subtraction result by 4 gives the number 0f words. Number of bytes = 4 * number of words
  end function;

begin

  -- Always ready
  o_wb_stall <= '0';

  --Command edge detection and state machine trigger
  --Capture the START bit (ctrl_reg[0]) transition to start operation
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        start_cmd<= '0';
      else
        --Capture START bit when written and operation is idle
        if (state=IDLE and ctrl_reg(0)='1') then
          start_cmd<= '1';
        else
          start_cmd<= '0';
        end if;
      end if;
    end if;
  end process;


  --Tensor artithemtic state machine
  process(clk)
  begin
    if rising_edge(clk) then
      if(reset = '1') then
        state<= IDLE;
        index<= 0;
        status_reg<= (others => '0');
      else
        case state is
          when IDLE =>
            if(start_cmd='1') then  --Triggered by START bit capture
              state<= PERFORMING_OPERATION;
              index<= 0;
              status_reg(0)<= '1';  --Busy flag
              status_reg(1)<= '0';  --Clear done flag
            end if;

          when PERFORMING_OPERATION =>
            case ctrl_reg(5 downto 1) is
                when OP_ADD =>
                  tensor_R(index)<= add_packed_int8(
                    tensor_A(index), 
                    tensor_B(index), 
                    tensor_C(index)
                  );
                
                when OP_SUB =>
                  tensor_R(index)<= sub_packed_int8(
                    tensor_A(index), 
                    tensor_B(index), 
                    tensor_C(index)
                  );
                
                when others =>
                  --Unsupported operation: fill result with zeros
                  tensor_R(index)<=(others=>'0');
              end case;
            if(index=TENSOR_WORDS-1) then
                state<=DONE;
            else
                index<=index+1;
            end if;
          when DONE =>
            state<= IDLE;
            status_reg(0)<= '0';  --Clear busy flag
            status_reg(1)<= '1';  --Set done flag
        end case;
      end if;
    end if;
  end process;


  --Write tensor data
  process(clk)
    variable tensor_offset: natural;
  begin
    if rising_edge(clk) then

      if reset = '1' then
--            leds_r <= (others => '0');
        ctrl_reg<= (others => '0');
        dim_reg<= x"00000032";  --Default 50x50 (0x32=50 base 10)
      elsif (i_wb_cyc='1' and i_wb_stb='1' and i_wb_we='1') then

        --LED address
--        if i_wb_addr = LED_ADDRESS then
--          leds_r <= i_wb_data(7 downto 0);

        --Control register
        --Software writes 1 to START the operation, can write 0 to clear
--        elsif i_wb_addr = CTRL_REG_ADDR then
        if(i_wb_addr=CTRL_REG_ADDRESS) then
          ctrl_reg<=i_wb_data;

        --Dimension register
        elsif(i_wb_addr= DIM_REG_ADDRESS) then
          dim_reg<=i_wb_data;

        --Tensor A
        elsif(unsigned(i_wb_addr)>=unsigned(TENSOR_A_BASE) and 
              unsigned(i_wb_addr)<unsigned(TENSOR_A_BASE)+(TENSOR_WORDS*4)) then
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
          if(tensor_offset<TENSOR_WORDS) then
            tensor_A(tensor_offset)<=i_wb_data;
          end if;

        --Tensor B
        elsif(unsigned(i_wb_addr)>=unsigned(TENSOR_B_BASE) and 
              unsigned(i_wb_addr)<unsigned(TENSOR_B_BASE)+(TENSOR_WORDS*4)) then
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_B_BASE);
          if(tensor_offset<TENSOR_WORDS) then
            tensor_B(tensor_offset)<=i_wb_data;
          end if;

        --Tensor C
        elsif(unsigned(i_wb_addr)>=unsigned(TENSOR_C_BASE) and 
              unsigned(i_wb_addr)<unsigned(TENSOR_C_BASE)+(TENSOR_WORDS*4)) then
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_C_BASE);
          if (tensor_offset<TENSOR_WORDS) then
            tensor_C(tensor_offset)<=i_wb_data;
          end if;
        end if;
      end if;
    end if;
  end process;

--  leds<= leds_r;

  --Read tensor data
  process(clk)
    variable tensor_offset: natural;
  begin
    if rising_edge(clk) then
      if reset= '1' then
        data_r<= (others => '0');
      elsif (i_wb_cyc= '1' and i_wb_stb= '1' and i_wb_we= '0') then

        --LED address
--        if i_wb_addr = LED_ADDRESS then
--          data_r<= (31 downto 8 => '0') & leds_r;

        --Button address
--        elsif i_wb_addr = BUTTON_ADDRESS then
--          data_r<= (31 downto 3 => '0') & buttons;

        --Control register
--        elsif i_wb_addr = CTRL_REG_ADDR then
        if(i_wb_addr= CTRL_REG_ADDRESS) then
          data_r<=ctrl_reg;

        --Status register
        elsif(i_wb_addr=STATUS_REG_ADDRESS) then
          data_r<=status_reg;

        --Dimension register
        elsif(i_wb_addr=DIM_REG_ADDRESS) then
          data_r<=dim_reg;

        --Tensor A
        elsif(unsigned(i_wb_addr)>=unsigned(TENSOR_A_BASE) and 
              unsigned(i_wb_addr)<unsigned(TENSOR_A_BASE) + (TENSOR_WORDS * 4)) then
          tensor_offset:=get_tensor_offset(i_wb_addr, TENSOR_A_BASE);
          if(tensor_offset<TENSOR_WORDS) then
            data_r<=tensor_A(tensor_offset);
          else
            data_r<=(others => '0');
          end if;

        --Tensor B
        elsif(unsigned(i_wb_addr)>=unsigned(TENSOR_B_BASE) and 
              unsigned(i_wb_addr)<unsigned(TENSOR_B_BASE)+(TENSOR_WORDS*4)) then
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_B_BASE);
          if(tensor_offset<TENSOR_WORDS) then
            data_r<=tensor_B(tensor_offset);
          else
            data_r<=(others=>'0');
          end if;

        --Tensor C
        elsif(unsigned(i_wb_addr)>=unsigned(TENSOR_C_BASE) and 
              unsigned(i_wb_addr)<unsigned(TENSOR_C_BASE)+(TENSOR_WORDS*4)) then
          tensor_offset:= get_tensor_offset(i_wb_addr, TENSOR_C_BASE);
          if tensor_offset<TENSOR_WORDS then
            data_r<=tensor_C(tensor_offset);
          else
            data_r<=(others=>'0');
          end if;

        --Tensor R (result)
        elsif(unsigned(i_wb_addr)>=unsigned(TENSOR_R_BASE) and 
              unsigned(i_wb_addr)<unsigned(TENSOR_R_BASE)+(TENSOR_WORDS*4)) then
          tensor_offset:=get_tensor_offset(i_wb_addr, TENSOR_R_BASE);
          if(tensor_offset<TENSOR_WORDS) then
            data_r<=tensor_R(tensor_offset);
          else
            data_r<=(others =>'0');
          end if;
        else
          data_r<=(others =>'0');
        end if;
      end if;
    end if;
  end process;

  o_wb_data <= data_r;

  --------------------------------------------------------------------------
  -- Acknowledge
  --------------------------------------------------------------------------
  process(clk)
    variable is_valid_addr: std_ulogic;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        ack_r<= '0';
      else
        --Check if address is valid
        is_valid_addr:= '0';
        if (--i_wb_addr = LED_ADDRESS or 
            --i_wb_addr = BUTTON_ADDRESS or
            i_wb_addr= CTRL_REG_ADDRESS or
            i_wb_addr= STATUS_REG_ADDRESS or
            i_wb_addr= DIM_REG_ADDRESS or
            (unsigned(i_wb_addr)>=unsigned(TENSOR_A_BASE) and 
             unsigned(i_wb_addr)<unsigned(TENSOR_A_BASE)+(TENSOR_WORDS*4)) or
            (unsigned(i_wb_addr)>=unsigned(TENSOR_B_BASE) and 
             unsigned(i_wb_addr)<unsigned(TENSOR_B_BASE)+(TENSOR_WORDS*4)) or
            (unsigned(i_wb_addr)>=unsigned(TENSOR_C_BASE) and 
             unsigned(i_wb_addr)<unsigned(TENSOR_C_BASE)+(TENSOR_WORDS*4)) or
            (unsigned(i_wb_addr)>=unsigned(TENSOR_R_BASE) and 
             unsigned(i_wb_addr)<unsigned(TENSOR_R_BASE)+(TENSOR_WORDS*4))) then
          is_valid_addr:= '1';
        end if;

        if (i_wb_cyc= '1' and i_wb_stb='1' and is_valid_addr='1') then
          ack_r<= '1';
        else
          ack_r<= '0';
        end if;
      end if;
    end if;
  end process;

  o_wb_ack<= ack_r;

end architecture;
