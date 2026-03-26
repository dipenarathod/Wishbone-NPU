library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Package: basic arithmetic utilities and common tensor types
-- Packs four int8 values per 32-bit word; includes MAX_DIM and TENSOR_WORDS
package tensor_operations_basic_arithmetic is
  -- Operation code constants (5-bit)
  constant OP_ADD : std_ulogic_vector(4 downto 0) := "00000";  -- R = A + B + C
  constant OP_SUB : std_ulogic_vector(4 downto 0) := "00001";  -- R = A - B - C

  -- Tensor memory limits and packing
  constant MAX_DIM     : natural := 28;     -- Reduced from 50 to 28
  constant TENSOR_WORDS: natural := 196;    -- (28*28)/4 = 196 words
  type tensor_mem_type is array (0 to TENSOR_WORDS-1) of std_ulogic_vector(31 downto 0);

  -- Optional GEMM scalars
  type gemm_scalars_type is record
    alpha : signed(7 downto 0);
    beta  : signed(7 downto 0);
  end record;

  -- Compute packed word count for a given dim (dim x dim, 4 elems/word)
  function calculate_tensor_words(dim: std_ulogic_vector(31 downto 0)) return natural;

  -- Per-word int8 arithmetic (bytewise); truncation to 8b is retained to match existing behavior
  function add_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
  function sub_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
end package tensor_operations_basic_arithmetic;

-- tensor_operations_basic_arithmetic.vhd
package body tensor_operations_basic_arithmetic is
  function calculate_tensor_words(dim: std_ulogic_vector(31 downto 0)) return natural is
    variable dim_int      : natural;
    variable num_elements : natural;
  begin
    dim_int      := to_integer(unsigned(dim));
    num_elements := dim_int * dim_int;
    return (num_elements + 3) / 4;
  end function;
  -- Saturate 10-bit intermediate to 8-bit signed
  function sat10_to_8(x : signed(9 downto 0)) return signed is
  begin
    if x > to_signed(127, 10) then
      return to_signed(127, 8);
    elsif x < to_signed(-128, 10) then
      return to_signed(-128, 8);
    else
      return resize(x, 8);
    end if;
  end function;

  function add_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable result                     : std_ulogic_vector(31 downto 0);
    variable sum0, sum1, sum2, sum3     : signed(9 downto 0);
  begin
    sum0 := resize(signed(a(7  downto 0)), 10) + resize(signed(b(7  downto 0)), 10) + resize(signed(c(7  downto 0)), 10);
    sum1 := resize(signed(a(15 downto 8)), 10) + resize(signed(b(15 downto 8)), 10) + resize(signed(c(15 downto 8)), 10);
    sum2 := resize(signed(a(23 downto 16)),10) + resize(signed(b(23 downto 16)),10) + resize(signed(c(23 downto 16)),10);
    sum3 := resize(signed(a(31 downto 24)),10) + resize(signed(b(31 downto 24)),10) + resize(signed(c(31 downto 24)),10);

    result(7  downto 0)  := std_ulogic_vector(sat10_to_8(sum0));
    result(15 downto 8)  := std_ulogic_vector(sat10_to_8(sum1));
    result(23 downto 16) := std_ulogic_vector(sat10_to_8(sum2));
    result(31 downto 24) := std_ulogic_vector(sat10_to_8(sum3));
    return result;
  end function;

  function sub_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable result                      : std_ulogic_vector(31 downto 0);
    variable diff0, diff1, diff2, diff3  : signed(9 downto 0);
  begin
    diff0 := resize(signed(a(7  downto 0)), 10) - resize(signed(b(7  downto 0)), 10) - resize(signed(c(7  downto 0)), 10);
    diff1 := resize(signed(a(15 downto 8)), 10) - resize(signed(b(15 downto 8)), 10) - resize(signed(c(15 downto 8)), 10);
    diff2 := resize(signed(a(23 downto 16)),10) - resize(signed(b(23 downto 16)),10) - resize(signed(c(23 downto 16)),10);
    diff3 := resize(signed(a(31 downto 24)),10) - resize(signed(b(31 downto 24)),10) - resize(signed(c(31 downto 24)),10);

    result(7  downto 0)  := std_ulogic_vector(sat10_to_8(diff0));
    result(15 downto 8)  := std_ulogic_vector(sat10_to_8(diff1));
    result(23 downto 16) := std_ulogic_vector(sat10_to_8(diff2));
    result(31 downto 24) := std_ulogic_vector(sat10_to_8(diff3));
    return result;
  end function;

end package body;


