library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package tensor_operations_activation is
  -- 5-bit opcodes
  constant OP_SIGMOID : std_ulogic_vector(4 downto 0) := "00100";
  constant OP_RELU    : std_ulogic_vector(4 downto 0) := "00101"; -- new ReLU

  -- Scalar activations on int8
  function sigmoid(num : signed(7 downto 0)) return signed;
  function relu   (num : signed(7 downto 0)) return signed;

  -- Apply activation lane-wise on a packed word (4x int8 in 32 bits)
  function sigmoid_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
  function relu_packed_word   (word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
end package;

package body tensor_operations_activation is
  -- Linear approx: y = 0.5 + x/4
  -- 0.5 in Q0.7 => 64 (int8)
  function sigmoid(num : signed(7 downto 0)) return signed is
    variable x_div4 : signed(7 downto 0);
    variable temp   : signed(8 downto 0);
    variable result : signed(7 downto 0);
  begin
    x_div4 := shift_right(num, 2);
    temp   := resize(x_div4, 9) + to_signed(64, 9);  -- 64 = 0.5
    if    (temp < to_signed(0,   9)) then result := to_signed(0,   8);
    elsif (temp > to_signed(127, 9)) then result := to_signed(127, 8);
    else                                 result := resize(temp, 8);
    end if;
    return result;
  end function;

  -- ReLU: max(0, x)
  function relu(num : signed(7 downto 0)) return signed is
  begin
    if num < to_signed(0, 8) then
      return to_signed(0, 8);
    else
      return num;
    end if;
  end function;

  function sigmoid_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable r : std_ulogic_vector(31 downto 0);
  begin
    r(7  downto 0)  := std_ulogic_vector(sigmoid(signed(word(7  downto 0 ))));
    r(15 downto 8)  := std_ulogic_vector(sigmoid(signed(word(15 downto 8 ))));
    r(23 downto 16) := std_ulogic_vector(sigmoid(signed(word(23 downto 16))));
    r(31 downto 24) := std_ulogic_vector(sigmoid(signed(word(31 downto 24))));
    return r;
  end function;

  function relu_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable r : std_ulogic_vector(31 downto 0);
  begin
    r(7  downto 0)  := std_ulogic_vector(relu(signed(word(7  downto 0 ))));
    r(15 downto 8)  := std_ulogic_vector(relu(signed(word(15 downto 8 ))));
    r(23 downto 16) := std_ulogic_vector(relu(signed(word(23 downto 16))));
    r(31 downto 24) := std_ulogic_vector(relu(signed(word(31 downto 24))));
    return r;
  end function;
end package body;
