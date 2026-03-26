Library ieee;
Use ieee.std_logic_1164.All;
Use ieee.numeric_std.All;


Package tensor_operations_basic_arithmetic Is
	--Operation code constants (5-bit)
	Constant OP_ADD : Std_ulogic_vector(4 Downto 0) := "00000"; --R = A + B + C
	Constant OP_SUB : Std_ulogic_vector(4 Downto 0) := "00001"; --R = A - B - C

	
	Constant TENSOR_A_WORDS : Natural := 2500; 
	Constant TENSOR_A_BYTES : Natural := TENSOR_A_WORDS * 4;
	Type tensor_A_mem_type Is Array (0 To TENSOR_A_WORDS - 1) Of Std_ulogic_vector(31 Downto 0);
	
	Constant TENSOR_B_WORDS : Natural := 9000; 
	Constant TENSOR_B_BYTES : Natural := TENSOR_B_WORDS * 4;
	Type tensor_B_mem_type Is Array (0 To TENSOR_B_WORDS - 1) Of Std_ulogic_vector(31 Downto 0);

	Constant TENSOR_C_WORDS : Natural := 2000; 
	Constant TENSOR_C_BYTES : Natural := TENSOR_C_WORDS * 4;
	Type tensor_C_mem_type Is Array (0 To TENSOR_C_WORDS - 1) Of Std_ulogic_vector(31 Downto 0);

	Constant TENSOR_R_WORDS : Natural := 2500; 
	Constant TENSOR_R_BYTES : Natural := TENSOR_R_WORDS * 4;
	Type tensor_R_mem_type Is Array (0 To TENSOR_R_WORDS - 1) Of Std_ulogic_vector(31 Downto 0);
	-- (28*28)/4 = 196 words
	-- (50*50)/4 = 625 words
	-- (100*100)/4 = 2500 words
	--Constant TENSOR_BYTES : Natural := TENSOR_WORDS * 4;
	--Type tensor_mem_type Is Array (0 To TENSOR_WORDS - 1) Of Std_ulogic_vector(31 Downto 0);


End Package tensor_operations_basic_arithmetic;
