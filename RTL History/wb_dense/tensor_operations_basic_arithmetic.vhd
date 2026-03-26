Library ieee;
Use ieee.std_logic_1164.All;
Use ieee.numeric_std.All;

-- Package: basic arithmetic utilities and common tensor types
-- Packs four int8 values per 32-bit word; includes MAX_DIM and TENSOR_WORDS
Package tensor_operations_basic_arithmetic Is
	-- Operation code constants (5-bit)
	Constant OP_ADD : Std_ulogic_vector(4 Downto 0) := "00000"; -- R = A + B + C
	Constant OP_SUB : Std_ulogic_vector(4 Downto 0) := "00001"; -- R = A - B - C

	-- Tensor memory limits and packing
	Constant MAX_DIM : Natural := 100; -- Reduced from 50 to 28
	Constant TENSOR_WORDS : Natural := 2500; 
	-- (28*28)/4 = 196 words
	-- (50*50)/4 = 625 words
	-- (100*100)/4 = 2500 words
	Constant TENSOR_BYTES : Natural := TENSOR_WORDS * 4;
	Type tensor_mem_type Is Array (0 To TENSOR_WORDS - 1) Of Std_ulogic_vector(31 Downto 0);

	-- Compute packed word count for a given dim (dim x dim, 4 elems/word)
	Function calculate_tensor_words(dim : Std_ulogic_vector(31 Downto 0)) Return Natural;

	-- Per-word int8 arithmetic (bytewise); truncation to 8b is retained to match existing behavior
	Function add_packed_int8(a, b, c : Std_ulogic_vector(31 Downto 0)) Return Std_ulogic_vector;
	Function sub_packed_int8(a, b, c : Std_ulogic_vector(31 Downto 0)) Return Std_ulogic_vector;
End Package tensor_operations_basic_arithmetic;

-- tensor_operations_basic_arithmetic.vhd
Package Body tensor_operations_basic_arithmetic Is
	Function calculate_tensor_words(dim : Std_ulogic_vector(31 Downto 0)) Return Natural Is
		Variable dim_int : Natural;
		Variable num_elements : Natural;
	Begin
		dim_int := to_integer(unsigned(dim));
		num_elements := dim_int * dim_int;
		Return (num_elements + 3) / 4;
	End Function;
	-- Saturate 10-bit intermediate to 8-bit signed
	Function sat10_to_8(x : signed(9 Downto 0)) Return signed Is
	Begin
		If (x > to_signed(127, 10)) Then
			Return to_signed(127, 8);
		Elsif (x < to_signed(-128, 10)) Then
			Return to_signed(-128, 8);
		Else
			Return resize(x, 8);
		End If;
	End Function;

	Function add_packed_int8(a, b, c : Std_ulogic_vector(31 Downto 0)) Return Std_ulogic_vector Is
		Variable result : Std_ulogic_vector(31 Downto 0);
		Variable sum0, sum1, sum2, sum3 : signed(9 Downto 0);
	Begin
		sum0 := resize(signed(a(7 Downto 0)), 10) + resize(signed(b(7 Downto 0)), 10) + resize(signed(c(7 Downto 0)), 10);
		sum1 := resize(signed(a(15 Downto 8)), 10) + resize(signed(b(15 Downto 8)), 10) + resize(signed(c(15 Downto 8)), 10);
		sum2 := resize(signed(a(23 Downto 16)), 10) + resize(signed(b(23 Downto 16)), 10) + resize(signed(c(23 Downto 16)), 10);
		sum3 := resize(signed(a(31 Downto 24)), 10) + resize(signed(b(31 Downto 24)), 10) + resize(signed(c(31 Downto 24)), 10);

		result(7 Downto 0) := Std_ulogic_vector(sat10_to_8(sum0));
		result(15 Downto 8) := Std_ulogic_vector(sat10_to_8(sum1));
		result(23 Downto 16) := Std_ulogic_vector(sat10_to_8(sum2));
		result(31 Downto 24) := Std_ulogic_vector(sat10_to_8(sum3));
		Return result;
	End Function;

	Function sub_packed_int8(a, b, c : Std_ulogic_vector(31 Downto 0)) Return Std_ulogic_vector Is
		Variable result : Std_ulogic_vector(31 Downto 0);
		Variable diff0, diff1, diff2, diff3 : signed(9 Downto 0);
	Begin
		diff0 := resize(signed(a(7 Downto 0)), 10) - resize(signed(b(7 Downto 0)), 10) - resize(signed(c(7 Downto 0)), 10);
		diff1 := resize(signed(a(15 Downto 8)), 10) - resize(signed(b(15 Downto 8)), 10) - resize(signed(c(15 Downto 8)), 10);
		diff2 := resize(signed(a(23 Downto 16)), 10) - resize(signed(b(23 Downto 16)), 10) - resize(signed(c(23 Downto 16)), 10);
		diff3 := resize(signed(a(31 Downto 24)), 10) - resize(signed(b(31 Downto 24)), 10) - resize(signed(c(31 Downto 24)), 10);

		result(7 Downto 0) := Std_ulogic_vector(sat10_to_8(diff0));
		result(15 Downto 8) := Std_ulogic_vector(sat10_to_8(diff1));
		result(23 Downto 16) := Std_ulogic_vector(sat10_to_8(diff2));
		result(31 Downto 24) := Std_ulogic_vector(sat10_to_8(diff3));
		Return result;
	End Function;

End Package Body;