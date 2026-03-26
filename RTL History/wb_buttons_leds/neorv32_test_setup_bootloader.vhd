-- ================================================================================ --
-- NEORV32 - Test Setup Using The UART-Bootloader To Upload And Run Executables     --
-- -------------------------------------------------------------------------------- --
-- The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32              --
-- Copyright (c) NEORV32 contributors.                                              --
-- Copyright (c) 2020 - 2025 Stephan Nolting. All rights reserved.                  --
-- Licensed under the BSD-3-Clause license, see LICENSE for details.                --
-- SPDX-License-Identifier: BSD-3-Clause                                            --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_test_setup_bootloader is
  generic (
    -- adapt these for your setup --
    CLOCK_FREQUENCY : natural := 100000000; -- clock frequency of clk_i in Hz
    IMEM_SIZE       : natural := 64*1024;   -- size of processor-internal instruction memory in bytes
    DMEM_SIZE       : natural := 64*1024     -- size of processor-internal data memory in bytes
  );
  port (
    -- Global control --
    clk_i       : in  std_ulogic; -- global clock, rising edge
    rstn_i      : in  std_ulogic; -- global reset, low-active, async
    -- GPIO --
    buttons    : in  std_ulogic_vector(2 downto 0);
    leds      : out std_ulogic_vector(7 downto 0); -- parallel output
    -- UART0 --
    uart0_txd_o : out std_ulogic; -- UART0 send data
    uart0_rxd_i : in  std_ulogic  -- UART0 receive data
  );
end entity;


architecture neorv32_test_setup_bootloader_rtl of neorv32_test_setup_bootloader is

  -- Component declaration
  component wb_buttons_leds
    generic (
      BASE_ADDRESS    : std_ulogic_vector(31 downto 0) := x"90000000";
      LED_ADDRESS     : std_ulogic_vector(31 downto 0) := x"90000000";
      BUTTON_ADDRESS  : std_ulogic_vector(31 downto 0) := x"90000004"
    );
    port (
      clk        : in  std_ulogic;
      reset      : in  std_ulogic;
      i_wb_cyc   : in  std_ulogic;
      i_wb_stb   : in  std_ulogic;
      i_wb_we    : in  std_ulogic;
      i_wb_addr  : in  std_ulogic_vector(31 downto 0);
      i_wb_data  : in  std_ulogic_vector(31 downto 0);
      o_wb_ack   : out std_ulogic;
      o_wb_stall : out std_ulogic;
      o_wb_data  : out std_ulogic_vector(31 downto 0);
      buttons    : in  std_ulogic_vector(2 downto 0);
      leds       : out std_ulogic_vector(7 downto 0)
    );
  end component;

  signal con_gpio_out : std_ulogic_vector(31 downto 0);
  signal rstn_internal:std_ulogic;  --internal signal to invert the reset signal
  signal wb_stall: std_logic;
    -- External bus interface (available if XBUS_EN = true) --
  signal  xbus_adr_o :std_ulogic_vector(31 downto 0);                    -- address
  signal  xbus_dat_o     : std_ulogic_vector(31 downto 0);                    -- write data
  signal  xbus_cti_o     : std_ulogic_vector(2 downto 0);                     -- cycle type
  signal  xbus_tag_o     : std_ulogic_vector(2 downto 0);                     -- access tag
  signal  xbus_we_o      : std_ulogic;                                        -- read/write
  signal  xbus_sel_o     : std_ulogic_vector(3 downto 0);                     -- byte enable
  signal  xbus_stb_o     : std_ulogic;                                        -- strobe
  signal  xbus_cyc_o     : std_ulogic;                                        -- valid cycle
  signal  xbus_dat_i     :  std_ulogic_vector(31 downto 0) := (others => 'L'); -- read data
  signal  xbus_ack_i     :  std_ulogic := 'L';                                 -- transfer acknowledge
  signal  xbus_err_i     :  std_ulogic := 'L';                                 -- transfer error
begin
  rstn_internal <= not(rstn_i);
  -- The Core Of The Problem ----------------------------------------------------------------
  -- -------------------------------------------------------------------------------------------
  neorv32_top_inst: neorv32_top
  generic map (
    -- Clocking --
    CLOCK_FREQUENCY  => CLOCK_FREQUENCY,   -- clock frequency of clk_i in Hz
    -- Boot Configuration --
    BOOT_MODE_SELECT => 0,                 -- boot via internal bootloader
    -- RISC-V CPU Extensions --
    RISCV_ISA_C      => true,              -- implement compressed extension?
    RISCV_ISA_M      => true,              -- implement mul/div extension?
    RISCV_ISA_Zicntr => true,              -- implement base counters?
    -- Internal Instruction memory --
    IMEM_EN          => true,              -- implement processor-internal instruction memory
    IMEM_SIZE        => IMEM_SIZE, -- size of processor-internal instruction memory in bytes
    -- Internal Data memory --
    DMEM_EN          => true,              -- implement processor-internal data memory
    DMEM_SIZE        => DMEM_SIZE, -- size of processor-internal data memory in bytes
    -- Processor peripherals --
    IO_GPIO_NUM      => 8,                 -- number of GPIO input/output pairs (0..32)
    IO_CLINT_EN      => true,              -- implement core local interruptor (CLINT)?
    IO_UART0_EN      => true,               -- implement primary universal asynchronous receiver/transmitter (UART0)?
    XBUS_EN => true,
    XBUS_TIMEOUT => 0

  )
  port map (
    -- Global control --
    clk_i       => clk_i,        -- global clock, rising edge
    rstn_i      => rstn_internal,       -- global reset, low-active, async
    -- GPIO (available if IO_GPIO_NUM > 0) --
    --gpio_o      => con_gpio_out, -- parallel output
    -- primary UART0 (available if IO_UART0_EN = true) --
    uart0_txd_o => uart0_txd_o,  -- UART0 send data
    uart0_rxd_i => uart0_rxd_i,   -- UART0 receive data
    xbus_adr_o =>   xbus_adr_o,               -- address
    xbus_dat_o =>   xbus_dat_o,                   -- write data
    xbus_cti_o =>   xbus_cti_o,                    -- cycle type
    xbus_tag_o =>   xbus_tag_o,                    -- access tag
    xbus_we_o =>   xbus_we_o,                                        -- read/write
    xbus_sel_o =>   xbus_sel_o,                  -- byte enable
    xbus_stb_o =>   xbus_stb_o,                                       -- strobe
    xbus_cyc_o =>   xbus_cyc_o,                                        -- valid cycle
    xbus_dat_i =>   xbus_dat_i,-- read data
    xbus_ack_i =>   xbus_ack_i,                              -- transfer acknowledge
    xbus_err_i =>   xbus_err_i                               -- transfer error
  );

  wb_buttons_leds_inst:wb_buttons_leds
  generic map(
      BASE_ADDRESS  => x"90000000",
      LED_ADDRESS   =>  x"90000000",
      BUTTON_ADDRESS  => x"90000004"  
  )
  port map(
    clk=>clk_i,
    reset=>rstn_i,
    i_wb_cyc => xbus_cyc_o,
    i_wb_stb =>xbus_stb_o,
    i_wb_we  => xbus_we_o,
    i_wb_addr => xbus_adr_o,
    i_wb_data => xbus_dat_o,
    o_wb_ack  => xbus_ack_i,
    o_wb_stall => open,
    o_wb_data => xbus_dat_i,
    buttons   => buttons,
    leds      => leds
  );
  xbus_err_i <= '0';
  -- GPIO output --
  --gpio_o <= con_gpio_out(7 downto 0);
    

end architecture;
