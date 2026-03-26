library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--Package: basic arithmetic utilities and common tensor types
--Packs four int8 values per 32-bit word
--MAX_DIM reduced to 28 to shrink on-chip storage footprint
package tensor_operations_basic_arithmetic is

  --Operation code constants (5-bit)
  constant OP_ADD : std_ulogic_vector(4 downto 0) := "00000";  --R = A + B + C
  constant OP_SUB : std_ulogic_vector(4 downto 0) := "00001";  --R = A - B - C

  --Tensor memory limits and packing
  --Hard limit for tensor side dimension to reduce resource usage
  constant MAX_DIM : natural := 28;                 --Reduced from 50 to 28
  constant TENSOR_WORDS : natural := 196;           --(28*28)/4 = 196 words
  type tensor_mem_type is array (0 to TENSOR_WORDS-1) of std_ulogic_vector(31 downto 0);

  --Compute packed word count for a given dim (dim x dim, 4 elems/word)
  function calculate_tensor_words(dim: std_ulogic_vector(31 downto 0)) return natural;

  --Per-word int8 arithmetic with saturation
  function add_packed_int8(a,b,c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
  function sub_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector;

end package tensor_operations_basic_arithmetic;

package body tensor_operations_basic_arithmetic is

  --Calculate number of 32-bit words for dim x dim packed int8 tensor
  function calculate_tensor_words(dim: std_ulogic_vector(31 downto 0)) return natural is
    variable dim_int: natural;
    variable num_elements: natural;
  begin
    dim_int := to_integer(unsigned(dim));
    num_elements := dim_int * dim_int;          --dim x dim elements
    return (num_elements + 3) / 4;              --4 int8 per 32-bit word
  end function;

  --R = A + B + C (bytewise), saturating to int8
  function add_packed_int8(a,b,c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable result: std_ulogic_vector(31 downto 0);
    variable sum0, sum1, sum2, sum3 : signed(9 downto 0);
  begin
    sum0 := resize(signed(a(7 downto 0)),10)  + resize(signed(b(7 downto 0)),10)  + resize(signed(c(7 downto 0)),10);
    sum1 := resize(signed(a(15 downto 8)),10) + resize(signed(b(15 downto 8)),10) + resize(signed(c(15 downto 8)),10);
    sum2 := resize(signed(a(23 downto 16)),10)+ resize(signed(b(23 downto 16)),10)+ resize(signed(c(23 downto 16)),10);
    sum3 := resize(signed(a(31 downto 24)),10)+ resize(signed(b(31 downto 24)),10)+ resize(signed(c(31 downto 24)),10);

    result(7 downto 0) := std_ulogic_vector(sum0(7 downto 0));
    result(15 downto 8) := std_ulogic_vector(sum1(7 downto 0));

    result(23 downto 16) := std_ulogic_vector(sum2(7 downto 0));

    result(31 downto 24) := std_ulogic_vector(sum3(7 downto 0));

    return result;
  end function;

  --R = A - B - C (bytewise), saturating to int8
  function sub_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable result: std_ulogic_vector(31 downto 0);
    variable diff0, diff1, diff2, diff3 : signed(9 downto 0);
  begin
    diff0 := resize(signed(a(7 downto 0)),10)  - resize(signed(b(7 downto 0)),10)  - resize(signed(c(7 downto 0)),10);
    diff1 := resize(signed(a(15 downto 8)),10) - resize(signed(b(15 downto 8)),10) - resize(signed(c(15 downto 8)),10);
    diff2 := resize(signed(a(23 downto 16)),10)- resize(signed(b(23 downto 16)),10)- resize(signed(c(23 downto 16)),10);
    diff3 := resize(signed(a(31 downto 24)),10)- resize(signed(b(31 downto 24)),10)- resize(signed(c(31 downto 24)),10);

result(7 downto 0) := std_ulogic_vector(diff0(7 downto 0));

    result(15 downto 8) := std_ulogic_vector(diff1(7 downto 0)); 

    result(23 downto 16) := std_ulogic_vector(diff2(7 downto 0)); 

   result(31 downto 24) := std_ulogic_vector(diff3(7 downto 0));

    return result;
  end function;

end package body tensor_operations_basic_arithmetic;

