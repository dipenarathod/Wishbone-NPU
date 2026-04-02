-- ================================================================================ --
-- NEORV32 Templates - Minimal generic setup with the bootloader enabled --
-- -------------------------------------------------------------------------------- --
-- The NEORV32 RISC-V Processor - https://github.com/stnolting/neorv32 --
-- Copyright (c) NEORV32 contributors. --
-- Copyright (c) 2020 - 2025 Stephan Nolting. All rights reserved. --
-- Licensed under the BSD-3-Clause license, see LICENSE for details. --
-- SPDX-License-Identifier: BSD-3-Clause --
-- ================================================================================ --

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY neorv32;
USE neorv32.neorv32_package.ALL;
ENTITY neorv32_ProcessorTop_MinimalBoot IS
	GENERIC (
		-- Clocking --
		CLOCK_FREQUENCY : NATURAL := 0; -- clock frequency of clk_i in Hz
		-- Internal Instruction memory --
		IMEM_EN : BOOLEAN := true; -- implement processor-internal instruction memory
		IMEM_SIZE : NATURAL := 64 * 1024; -- size of processor-internal instruction memory in bytes
		-- Internal Data memory --
		DMEM_EN : BOOLEAN := true; -- implement processor-internal data memory
		DMEM_SIZE : NATURAL := 64 * 1024; -- size of processor-internal data memory in bytes
		-- Processor peripherals --
		IO_GPIO_NUM : NATURAL := 4 -- number of GPIO input/output pairs (0..32)
		--IO_PWM_NUM_CH : natural := 3 -- number of PWM channels to implement (0..16)
	);
	PORT (
		-- Global control --
		clk_i : IN std_logic;
		rstn_i : IN std_logic;
		-- GPIO (available if IO_GPIO_EN = true) --
		gpio_o : OUT std_ulogic_vector(IO_GPIO_NUM - 1 DOWNTO 0);
		-- primary UART0 (available if IO_UART0_EN = true) --
		uart_txd_o : OUT std_ulogic; -- UART0 send data
		uart_rxd_i : IN std_ulogic := '0' -- UART0 receive data
		-- PWM (available if IO_PWM_NUM_CH > 0) --
		--pwm_o : out std_ulogic_vector(IO_PWM_NUM_CH-1 downto 0)
		--Interface for the camera harware
	);
END ENTITY;

ARCHITECTURE neorv32_ProcessorTop_MinimalBoot_rtl OF neorv32_ProcessorTop_MinimalBoot IS

	-- internal IO connection --
	SIGNAL con_gpio_o : std_ulogic_vector(31 DOWNTO 0);
	SIGNAL con_pwm_o : std_ulogic_vector(15 DOWNTO 0);

	SIGNAL rstn_internal : std_ulogic; --internal signal to invert the reset signal
 

	-- External bus interface (available if XBUS_EN = true) --
	--Now connected to the interconnect
	SIGNAL xbus_adr_o : std_ulogic_vector(31 DOWNTO 0); -- address
	SIGNAL xbus_dat_o : std_ulogic_vector(31 DOWNTO 0); -- write data
	SIGNAL xbus_cti_o : std_ulogic_vector(2 DOWNTO 0); -- cycle type
	SIGNAL xbus_tag_o : std_ulogic_vector(2 DOWNTO 0); -- access tag
	SIGNAL xbus_we_o : std_ulogic; -- read/write
	SIGNAL xbus_sel_o : std_ulogic_vector(3 DOWNTO 0); -- byte enable
	SIGNAL xbus_stb_o : std_ulogic; -- strobe
	SIGNAL xbus_cyc_o : std_ulogic; -- valid cycle
	SIGNAL xbus_dat_i : std_ulogic_vector(31 DOWNTO 0) := (OTHERS => 'L'); -- read data
	SIGNAL xbus_ack_i : std_ulogic := 'L'; -- transfer acknowledge
	SIGNAL xbus_err_i : std_ulogic := 'L'; -- transfer error
 
 
BEGIN
	rstn_internal <= NOT(rstn_i);
	-- The core of the problem ----------------------------------------------------------------
	-- -------------------------------------------------------------------------------------------
	neorv32_inst : ENTITY neorv32.neorv32_top
			GENERIC MAP(
			-- Clocking --
			CLOCK_FREQUENCY => CLOCK_FREQUENCY, -- clock frequency of clk_i in Hz
			-- Boot Configuration --
			BOOT_MODE_SELECT => 0, -- boot via internal bootloader
			-- RISC-V CPU Extensions --
			RISCV_ISA_Zicntr => true, -- implement base counters?
			RISCV_ISA_M => true, -- implement mul/div extension?
			RISCV_ISA_C => true, -- implement compressed extension?
			-- Internal Instruction memory --
			IMEM_EN => true, -- implement processor-internal instruction memory
			IMEM_SIZE => IMEM_SIZE, -- size of processor-internal instruction memory in bytes
			-- Internal Data memory --
			DMEM_EN => true, -- implement processor-internal data memory
			DMEM_SIZE => DMEM_SIZE, -- size of processor-internal data memory in bytes
			-- Processor peripherals --
			IO_GPIO_NUM => IO_GPIO_NUM, -- number of GPIO input/output pairs (0..32)
			IO_CLINT_EN => true, -- implement core local interruptor (CLINT)?
			IO_UART0_EN => true, -- implement primary universal asynchronous receiver/transmitter (UART0)?
			--IO_PWM_NUM_CH => IO_PWM_NUM_CH, -- number of PWM channels to implement (0..12); 0 = disabled
			XBUS_EN => true, 
			XBUS_TIMEOUT => 20
			)
			PORT MAP(
				-- Global control --
				clk_i => clk_i, -- global clock, rising edge
				rstn_i => rstn_i, -- global reset, low-active, async
				-- GPIO (available if IO_GPIO_NUM > 0) --
				gpio_o => con_gpio_o, -- parallel output
				--gpio_i => (others => '0'), -- parallel input
				-- primary UART0 (available if IO_UART0_EN = true) --
				uart0_txd_o => uart_txd_o, -- UART0 send data
				uart0_rxd_i => uart_rxd_i, -- UART0 receive data
				-- PWM (available if IO_PWM_NUM_CH > 0) --
				--pwm_o => con_pwm_o, -- pwm channels
				xbus_adr_o => xbus_adr_o, -- address
				xbus_dat_o => xbus_dat_o, -- write data
				xbus_cti_o => xbus_cti_o, -- cycle type
				xbus_tag_o => xbus_tag_o, -- access tag
				xbus_we_o => xbus_we_o, -- read/write
				xbus_sel_o => xbus_sel_o, -- byte enable
				xbus_stb_o => xbus_stb_o, -- strobe
				xbus_cyc_o => xbus_cyc_o, -- valid cycle
				xbus_dat_i => xbus_dat_i, -- read data
				xbus_ack_i => xbus_ack_i, -- transfer acknowledge
				xbus_err_i => xbus_err_i -- transfer error
			);
END ARCHITECTURE;