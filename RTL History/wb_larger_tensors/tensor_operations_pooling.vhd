Library ieee;
Use ieee.std_logic_1164.All;
Use ieee.numeric_std.All;

Library work;
Use work.tensor_operations_basic_arithmetic.All; --MAX_DIM cap and tensor_mem_type layout [packed 4x int8/word]

Package tensor_operations_pooling Is
	--5-bit opcodes (used by CTRL[5:1]) to select pooling mode in the peripheral

	Constant OP_MAXPOOL : Std_ulogic_vector(4 Downto 0) := "00010"; --Max pooling opcode
	Constant OP_AVGPOOL : Std_ulogic_vector(4 Downto 0) := "00011"; --Average pooling opcode

	--Compute flat index for 2x2 windows
	Function compute_pooling_flat_index_2x2(
		read_index : unsigned (1 Downto 0);
		base_i_reg : unsigned(15 Downto 0);
		din_reg    : unsigned(7 Downto 0)
	) Return unsigned;

	--2x2 max pooling. Returns the maximum of the four signed 8-bit inputs
	--Naming convention: numRC where R is row within the 2x2 window and C is the column
	Function maxpool4(
		num00, num01, num10, num11 : signed(7 Downto 0)
	) Return signed;

	--2x2 average pooling. Arithmetic mean of four signed 8-bit inputs
	--Values are first widened to 10 bits and summed
	--Right-shift by 2 divides by 4 (exact for integers), then narrowed back to 8 bits
	--The mean of four int8 values always fits into int8 range, so no saturation is needed
	--Googled this method entirely. Resizing is too complicated for me to understand it yet
	Function avgpool4(
		num00, num01, num10, num11 : signed(7 Downto 0)
	) Return signed;
End Package;

Package Body tensor_operations_pooling Is
	--Compute flat index for 2x2 windows
	Function compute_pooling_flat_index_2x2(read_index : unsigned (1 Downto 0); base_i_reg : unsigned(15 Downto 0); din_reg : unsigned(7 Downto 0)) Return unsigned Is
		Variable elem_index : unsigned (15 Downto 0);
	Begin
		Case read_index Is
			When "00" => elem_index := base_i_reg; --(0,0)
			When "01" => elem_index := base_i_reg + 1; --(0,1)
			When "10" => elem_index := base_i_reg + resize(din_reg, elem_index'length); --(1,0)
			When Others => elem_index := base_i_reg + resize(din_reg, elem_index'length) + 1; --(1,1)
		End Case;
		Return elem_index;
	End Function;
	--2x2 max pooling over four signed int8 inputs
	--Three comparisons is enough
	--compare num01, num10, and num11 against the maximum, which is initailly num00
	Function maxpool4(num00, num01, num10, num11 : signed(7 Downto 0)) Return signed Is
		Variable running_max : signed(7 Downto 0) := num00;
	Begin
		If (num01 > running_max) Then
			running_max := num01;
		End If;
		If (num10 > running_max) Then
			running_max := num10;
		End If;
		If (num11 > running_max) Then
			running_max := num11;
		End If;
		Return running_max; --Final maximum element 
	End Function;

	--2x2 average pooling over four signed int8 inputs
	--Steps:
	--1) Widen operands to 10 bits to avoid overflow during addition: the min/max sum is 4*(-128)=-512 or 4*(127)=508
	--2) Sum all four values in 10-bit precision
	--3) Right-shift by 2 to divide by 4 (exact integer division), producing the arithmetic mean
	--4) Narrow back to 8 bits; the result is guaranteed to be within [-128, 127], so no saturation is required
	-- tensor_operations_pooling.vhd
	Function avgpool4(num00, num01, num10, num11 : signed(7 Downto 0)) Return signed Is
		Variable sum_wide : signed(9 Downto 0);
		Variable sum_adj : signed(9 Downto 0);
	Begin
		sum_wide := resize(num00, 10) + resize(num01, 10) + resize(num10, 10) + resize(num11, 10);
		If (sum_wide >= 0) Then
			sum_adj := sum_wide + to_signed(2, 10); -- bias for /4 rounding (non-negative)
		Else
			sum_adj := sum_wide + to_signed(1, 10); -- bias for /4 rounding (negative)
		End If;
		Return resize(shift_right(sum_adj, 2), 8);
	End Function;
End Package Body;