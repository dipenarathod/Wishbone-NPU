
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity wb_buttons_leds is
  generic (
    BASE_ADDRESS    : std_ulogic_vector(31 downto 0) := x"90000000";
    LED_ADDRESS     : std_ulogic_vector(31 downto 0) := x"90000000";
    BUTTON_ADDRESS  : std_ulogic_vector(31 downto 0) := x"90000004"
  );
  port (
    clk        : in  std_ulogic;
    reset      : in  std_ulogic;

    -- Wishbone interface
    i_wb_cyc   : in  std_ulogic;
    i_wb_stb   : in  std_ulogic;
    i_wb_we    : in  std_ulogic;
    i_wb_addr  : in  std_ulogic_vector(31 downto 0);
    i_wb_data  : in  std_ulogic_vector(31 downto 0);
    o_wb_ack   : out std_ulogic;
    o_wb_stall : out std_ulogic;
    o_wb_data  : out std_ulogic_vector(31 downto 0);

    -- I/O
    buttons    : in  std_ulogic_vector(2 downto 0);
    leds       : out std_ulogic_vector(7 downto 0)
  );
end entity;

architecture rtl of wb_buttons_leds is
  signal leds_r    : std_ulogic_vector(7 downto 0) := (others => '0');
  signal data_r    : std_ulogic_vector(31 downto 0) := (others => '0');
  signal ack_r     : std_ulogic := '0';
begin

  --------------------------------------------------------------------------
  -- Always ready
  --------------------------------------------------------------------------
  o_wb_stall <= '0';

  --------------------------------------------------------------------------
  -- Write: update LEDs
  --------------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        leds_r <= (others => '0');
      elsif (i_wb_cyc = '1' and i_wb_stb = '1' and i_wb_we = '1'
             and i_wb_addr = LED_ADDRESS) then
        leds_r <= i_wb_data(7 downto 0);
      end if;
    end if;
  end process;

  leds <= leds_r;

  --------------------------------------------------------------------------
  -- Read: prepare data
  --------------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        data_r <= (others => '0');
      elsif (i_wb_cyc = '1' and i_wb_stb = '1' and i_wb_we = '0') then
        if i_wb_addr = LED_ADDRESS then
          data_r <= (31 downto 8 => '0') & leds_r;
        elsif i_wb_addr = BUTTON_ADDRESS then
          data_r <= (31 downto 3 => '0') & buttons;
        else
          data_r <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  o_wb_data <= data_r;

  --------------------------------------------------------------------------
  -- Acknowledge
  --------------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        ack_r <= '0';
      else
        if (i_wb_cyc = '1' and i_wb_stb = '1'
            and (i_wb_addr = LED_ADDRESS or i_wb_addr = BUTTON_ADDRESS)) then
          ack_r <= '1';
        else
          ack_r <= '0';
        end if;
      end if;
    end if;
  end process;

  o_wb_ack <= ack_r;

end architecture;