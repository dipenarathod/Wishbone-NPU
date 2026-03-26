Library ieee;
Use ieee.std_logic_1164.All;
Use ieee.numeric_std.All;

--Notes cause no paper
--Variable number of input channels and output channels (get by new register) or use loops in Ada
--Store input channel (feature) width in dim register as it will be different across layers
--Store at R out index?
--No padding
--Stride of 1
--Reuse quantize logic registers (and even the functions from the dense package if possible)
--In dense we multiply corresponding elements. Here we multiply matrices


Package tensor_operations_conv2d Is

	Constant OP_CONV : Std_ulogic_vector(4 Downto 0) := "01000"; --Conv layer opcode (5-bit)
end Package;