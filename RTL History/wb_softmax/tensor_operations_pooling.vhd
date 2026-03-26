library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.tensor_operations_basic_arithmetic.all;  --MAX_DIM cap and tensor_mem_type layout [packed 4x int8/word]

package tensor_operations_pooling is
  --5-bit opcodes (used by CTRL[5:1]) to select pooling mode in the peripheral

  constant OP_MAXPOOL: std_ulogic_vector(4 downto 0):= "00010"; --Max pooling opcode
  constant OP_AVGPOOL: std_ulogic_vector(4 downto 0):= "00011"; --Average pooling opcode

  --Read one signed int8 element from a packed tensor by flat element index
  --4 consecutive int8 in a 32 bit word
  --word(7:0)   = element 0, word(15:8)  = element 1,etc
  --elem_index is an index for the 1D interpretation of the 2D tensor, NOT a byte address
  --If a tensor is NxN, elem_index can be 0 to N*N-1
  function read_int_in_word(
    constant A: tensor_mem_type;
    elem_index: natural         
  ) return signed;

  --2x2 max pooling. Returns the maximum of the four signed 8-bit inputs
  --Naming convention: numRC where R is row within the 2x2 window and C is the column
  function maxpool4(
    num00, num01, num10, num11: signed(7 downto 0)
  ) return signed;

  --2x2 average pooling. Arithmetic mean of four signed 8-bit inputs
  --Values are first widened to 10 bits and summed
  --Right-shift by 2 divides by 4 (exact for integers), then narrowed back to 8 bits
  --The mean of four int8 values always fits into int8 range, so no saturation is needed
  --Googled this method entirely. Resizing is too complicated for me to understand it yet
  function avgpool4(
    num00, num01, num10, num11: signed(7 downto 0)
  ) return signed;
end package;

package body tensor_operations_pooling is

  function read_int_in_word(constant A: tensor_mem_type; elem_index: natural) return signed is
    --Index of the 32-bit word in A that contains the requested element
    variable word_index: natural:= elem_index / 4;
    --Byte position within the 32-bit word: 0 is bits[7:0], 1 is bits[15:8], etc.
    variable byte_select: natural:= elem_index mod 4;
    --variable to store A[word_index]
    variable packed_word: std_ulogic_vector(31 downto 0);
    --variable to store selected_byte
    variable selected_byte: std_ulogic_vector(7 downto 0);
  begin
    packed_word:= A(word_index);  --BRAM read in the peripheral; here it is a pure array access
    case byte_select is
      when 0 => selected_byte:= packed_word(7  downto 0);   --element 0 in this word
      when 1 => selected_byte:= packed_word(15 downto 8);   --element 1 in this word
      when 2 => selected_byte:= packed_word(23 downto 16);  --element 2 in this word
      when others => selected_byte:= packed_word(31 downto 24); --element 3 in this word
    end case;
    --Reinterpret the 8-bit pattern as a signed value (two's complement) and return it
    return signed(selected_byte); --Googled this signed syntax
  end function;

  --2x2 max pooling over four signed int8 inputs
  --Three comparisons is enough
  --compare num01, num10, and num11 against the maximum, which is initailly num00
  function maxpool4(num00, num01, num10, num11: signed(7 downto 0)) return signed is
    variable running_max: signed(7 downto 0):= num00;
  begin
    if num01 > running_max then 
        running_max:= num01; 
    end if;
    if num10 > running_max then 
        running_max:= num10; 
    end if;
    if num11 > running_max then 
        running_max:= num11; 
    end if;
    return running_max; --Final maximum element 
  end function;

  --2x2 average pooling over four signed int8 inputs
  --Steps:
  --1) Widen operands to 10 bits to avoid overflow during addition: the min/max sum is 4*(-128)=-512 or 4*(127)=508
  --2) Sum all four values in 10-bit precision
  --3) Right-shift by 2 to divide by 4 (exact integer division), producing the arithmetic mean
  --4) Narrow back to 8 bits; the result is guaranteed to be within [-128, 127], so no saturation is required
-- tensor_operations_pooling.vhd
function avgpool4(num00, num01, num10, num11: signed(7 downto 0)) return signed is
  variable sum_wide : signed(9 downto 0);
  variable sum_adj  : signed(9 downto 0);
begin
  sum_wide := resize(num00, 10) + resize(num01, 10) + resize(num10, 10) + resize(num11, 10);
  if sum_wide >= 0 then
    sum_adj := sum_wide + to_signed(2, 10); -- bias for /4 rounding (non-negative)
  else
    sum_adj := sum_wide + to_signed(1, 10); -- bias for /4 rounding (negative)
  end if;
  return resize(shift_right(sum_adj, 2), 8);
end function;


end package body;

