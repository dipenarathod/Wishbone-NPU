-- #################################################################################################
-- # << NEORV32 - Example setup including the bootloader, for the ECP5EVN (c) Board >> #
-- # ********************************************************************************************* #
-- # BSD 3-Clause License #
-- # #
-- # Copyright (c) 2023, Stephan Nolting. All rights reserved. #
-- # #
-- # Redistribution and use in source and binary forms, with or without modification, are #
-- # permitted provided that the following conditions are met: #
-- # #
-- # 1. Redistributions of source code must retain the above copyright notice, this list of #
-- # conditions and the following disclaimer. #
-- # #
-- # 2. Redistributions in binary form must reproduce the above copyright notice, this list of #
-- # conditions and the following disclaimer in the documentation and/or other materials #
-- # provided with the distribution. #
-- # #
-- # 3. Neither the name of the copyright holder nor the names of its contributors may be used to #
-- # endorse or promote products derived from this software without specific prior written #
-- # permission. #
-- # #
-- # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS #
-- # OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF #
-- # MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE #
-- # COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, #
-- # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE #
-- # GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED #
-- # AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING #
-- # NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED #
-- # OF THE POSSIBILITY OF SUCH DAMAGE. #
-- # ********************************************************************************************* #
-- # The NEORV32 Processor - https://github.com/stnolting/neorv32 (c) Stephan Nolting #
-- #################################################################################################

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY neorv32;
USE neorv32.neorv32_package.ALL;
ENTITY neorv32_ECP5EVN_BoardTop_MinimalBoot IS
	PORT (
		-- Clock and Reset inputs
		ECP5EVN_CLK : IN std_logic;
		ECP5EVN_RST_N : IN std_logic;
		-- LED outputs
		ECP5EVN_LED0 : OUT std_logic;
		ECP5EVN_LED1 : OUT std_logic;
		ECP5EVN_LED2 : OUT std_logic;
		ECP5EVN_LED3 : OUT std_logic;
		ECP5EVN_LED4 : OUT std_logic;
		ECP5EVN_LED5 : OUT std_logic;
		ECP5EVN_LED6 : OUT std_logic;
		ECP5EVN_LED7 : OUT std_logic;
		-- UART0
		ECP5EVN_RX : IN std_logic;
		ECP5EVN_TX : OUT std_logic
	);
END ENTITY;

ARCHITECTURE neorv32_ECP5EVN_BoardTop_MinimalBoot_rtl OF neorv32_ECP5EVN_BoardTop_MinimalBoot IS

	--clock frequency in Hz
	CONSTANT f_clock_c : NATURAL := 72_000_000;

	--PLL and clocking
	Signal clk_sys : Std_logic; --72 MHz system clock from PLL
	Signal pll_locked : Std_logic;
	Signal rstn_sync : Std_logic;



	-- internal IO connection --
	SIGNAL con_pwm : std_ulogic_vector(2 DOWNTO 0);
	SIGNAL con_gpio_o : std_ulogic_vector(3 DOWNTO 0);

BEGIN

	--Combine external reset with PLL lock
	rstn_sync <= ECP5EVN_RST_N And pll_locked;

	--PLL instantiation: generates 72 MHz system clock and 24 MHz camera clock
	PLL_12_To_72MHz_Inst : Entity work.PLL_12_To_72MHz
		Port Map(
			PLL_12_To_72MHz_Instance_CLKI  => ECP5EVN_CLK, --12 MHz input
			PLL_12_To_72MHz_Instance_CLKOP => clk_sys, --72 MHz system clock
			PLL_12_To_72MHz_Instance_LOCK  => pll_locked
		);

	neorv32_inst : ENTITY neorv32.neorv32_ProcessorTop_MinimalBoot
			GENERIC MAP(
			CLOCK_FREQUENCY => f_clock_c, --System clock (72 MHz)
			IMEM_SIZE => 64 * 1024, 
			DMEM_SIZE => 64 * 1024
			)
			PORT MAP(
				-- Global control --
				clk_i => std_ulogic(clk_sys), 
				rstn_i => std_ulogic(rstn_sync), 

				-- GPIO --
				gpio_o => con_gpio_o, 

				-- primary UART --
				uart_txd_o => ECP5EVN_TX, -- UART0 send data
				uart_rxd_i => ECP5EVN_RX -- UART0 receive data
			);

	--IO Connection --------------------------------------------------------------------------
	-------------------------------------------------------------------------------------------
	ECP5EVN_LED0 <= con_gpio_o(0);
	ECP5EVN_LED1 <= con_gpio_o(1);
	ECP5EVN_LED2 <= con_gpio_o(2);
	ECP5EVN_LED3 <= con_gpio_o(3);

END ARCHITECTURE;