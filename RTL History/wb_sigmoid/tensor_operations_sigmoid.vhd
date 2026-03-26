library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--library work;
--use work.tensor_operations_basic_arithmetic.all;  --MAX_DIM cap and tensor_mem_type layout [packed 4x int8/word]

package tensor_operations_sigmoid is
  --5-bit opcodes (used by CTRL[5:1]) to select pooling mode in the peripheral

  constant OP_SIGMOID: std_ulogic_vector(4 downto 0):= "00100"; --Sigmoid opcode
  function sigmoid(num:signed(7 downto 0)) return signed;   --Function to calculate sigmoid
  function sigmoid_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector; --function to calculate sigmoid on four bytes within a word
end package;

package body tensor_operations_sigmoid is

  --sigmoid approximate function = 0.5 + num/4
  --0.5 in Q0.7 = 64 int8
  function sigmoid(num:signed(7 downto 0)) return signed is
    --Compute y = 64 + (num>>2)
    --Using a larger temp variable in the intermediate step to handle overflow
    variable x_div4    : signed(7 downto 0);
    variable temp: signed(8 downto 0);
    variable result    : signed(7 downto 0);
  begin
    --arithmetic shift right by 2 to divide by 4
    x_div4:= shift_right(num, 2);
    --add 0.5 (64 in Q0.7)
    temp:= resize(x_div4, 9)+to_signed(64, 9);

    if(temp < to_signed(0, 9)) then
      result := to_signed(0, 8);
    elsif(temp > to_signed(127, 9)) then
      result:= to_signed(127, 8);
    else
      result:= resize(temp, 8);
    end if;
    return result;
  end function;

--Apply the single sigmoid funcion on 4 bytes inside a word
function sigmoid_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
  variable result: std_ulogic_vector(31 downto 0);
begin
  result(7  downto 0):= std_ulogic_vector(sigmoid(signed(word(7  downto 0 ))));
  result(15 downto 8):= std_ulogic_vector(sigmoid(signed(word(15 downto 8 ))));
  result(23 downto 16):= std_ulogic_vector(sigmoid(signed(word(23 downto 16))));
  result(31 downto 24):= std_ulogic_vector(sigmoid(signed(word(31 downto 24))));
  return result;
end function;


end package body;
