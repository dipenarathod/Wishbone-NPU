library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package tensor_operations_activation is
  -- 5-bit opcodes
  constant OP_SIGMOID : std_ulogic_vector(4 downto 0) := "00100"; --Sigmoid
  constant OP_RELU    : std_ulogic_vector(4 downto 0) := "00101"; --ReLU
  constant OP_SOFTMAX : std_ulogic_vector(4 downto 0) := "00110"; --Softmax pass 1: compute exponents. Pass 2 (div by sum) is combined using an internal flag
  --constant OP_SOFTMAX_DIV : std_ulogic_vector(4 downto 0) := "00111"; --Softmax pass 2: divide by sum

  -- Scalar activations on int8
  function sigmoid(num : signed(7 downto 0)) return signed;
  function relu   (num : signed(7 downto 0)) return signed;
  
  --Softmax helper functions
  --Linear approximation e^x ≈ 1 + x for x in [-1, 0.992]
  --We use unsigned Q0.7. Scale is 128, but an additional bit can be used for information. Results are always non-negative because e^x is always positive
  function softmax_exponent(num: signed(7 downto 0)) return unsigned;
  
  --Divide exponent by sum of all exponents to get softmax probability
  --Now, instead of dividing my sum, we multiply by intered sum. Division is a very costly vhdl operation
  --Multiplication can be accelerated using a DSP
  --Inverted sum is calculated by the Ada program
  function softmax_div_by_sum(num: unsigned(7 downto 0); inverted_sum: unsigned(15 downto 0)) return unsigned;
  
  -- Apply activation lane-wise on a packed word (4x int8 in 32 bits)
  function sigmoid_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
  function relu_packed_word   (word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
  
  --Softmax packed word functions
  --(Pass 1) Compute exponents of 4 elements
  function softmax_exponent_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector;
  --(Pass 2) Divide each exponent by sum (We actually multiply by inverted sum)
  function softmax_div_by_sum_packed_word(word : std_ulogic_vector(31 downto 0); inverted_sum: unsigned(15 downto 0)) return std_ulogic_vector;
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

  --Softmax exponent using linear approximation: e^x ≈ 1 + x
  --Output: unsigned Q0.7 (8 bits, always positive). We can't call it Q0.8 because our scaling factor is 128
  --128 = 2^7 =scaling factor of Q0.7
  --128 in unsigned Q0.7 = 1, so we add 128 to the signed input
  --1.992 is 1111_1111
  function softmax_exponent(num: signed(7 downto 0)) return unsigned is
    variable temp: signed(8 downto 0);
    variable result: unsigned(7 downto 0);
  begin
    --e^x ≈ 1 + x
    temp := resize(num, 9) + to_signed(128, 9);  --Add 1.0 in Q0.7
    
    --Clamp to unsigned range [0, 255] (8-bit range)
    if temp < to_signed(0, 9) then
      result := to_unsigned(0, 8);
    elsif temp > to_signed(255, 9) then
      result := to_unsigned(255, 8);
    else
      result := unsigned(temp(7 downto 0));
    end if;
    
    return result;
  end function;

  --Softmax division using pre-computed reciprocal from Ada
  --num: unsigned Q0.7 exponent (8 bits)
  --inverted_sum: pre-computed (2^16 / sum) from Ada (16 bits)
  --Returns: unsigned Q0.7 normalized probability
  function softmax_div_by_sum(num: unsigned(7 downto 0); inverted_sum: unsigned(15 downto 0)) return unsigned is
    variable numerator : unsigned(15 downto 0);
    variable product   : unsigned(31 downto 0);
    variable rounded   : unsigned(31 downto 0);
    variable result_8  : unsigned(7 downto 0);
  begin
    --Scale numerator by 128 (2^7) because we are dealing with Q0.7 numbers
    numerator := resize(num, 16) sll 7;  --(1.992 = 255) 255 * 128 = 32640 (and 32640 can fit in 15 bits, but 16 bits feels easier personally. Nothing more than personal comfort-DAR)
    
    --Multiply by inverted sum (will use DSP ideally, otherwise infer it)
    --product = (num * 128) * (2^16 / sum) = num * 128 * 2^16 / sum
    --Why (2^16)/sum and not 1/sum: we can't store  a fraction in an integer register
    --We want a good enough resolution sum, so we scale the inverted sum by 2^16 to get a Q0.16 number
    product := numerator * inverted_sum;
    
    --Add 0.5 for rounding (2^15 in this scale)
    --https://stackoverflow.com/questions/2422712/rounding-integer-division-instead-of-truncating
    --This stack overflow article helped in getting information lost in truncating back
    rounded := product + x"00008000";
    
    --Extract result by shifting right 16 bits
    --rounded >> 16 = (num * 128 * 2^16 / sum) >> 16 = num * 128 / sum
    --Scale down back to accommodate the scale of the sum
    result_8 := rounded(23 downto 16);
    
    --Clamp to Q0.7 range [0, 127]
    --We can optionally change this to unsigned Q0.7, but the Ada code wiill need another method
    if result_8 > to_unsigned(127, 8) then
      result_8 := to_unsigned(127, 8);
    end if;
    
    return result_8;
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

  --Softmax pass 1 (exponent of elements in packed word)
  function softmax_exponent_packed_word(word : std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable r : std_ulogic_vector(31 downto 0);
  begin
    r(7  downto 0)  := std_ulogic_vector(softmax_exponent(signed(word(7  downto 0 ))));
    r(15 downto 8)  := std_ulogic_vector(softmax_exponent(signed(word(15 downto 8 ))));
    r(23 downto 16) := std_ulogic_vector(softmax_exponent(signed(word(23 downto 16))));
    r(31 downto 24) := std_ulogic_vector(softmax_exponent(signed(word(31 downto 24))));
    return r;
  end function;

  --Softmax pass 2 (divide packed exponents by sum)
  function softmax_div_by_sum_packed_word(word : std_ulogic_vector(31 downto 0); inverted_sum: unsigned(15 downto 0)) return std_ulogic_vector is
    variable r : std_ulogic_vector(31 downto 0);
  begin
    r(7  downto 0)  := std_ulogic_vector(softmax_div_by_sum(unsigned(word(7  downto 0 )), inverted_sum));
    r(15 downto 8)  := std_ulogic_vector(softmax_div_by_sum(unsigned(word(15 downto 8 )), inverted_sum));
    r(23 downto 16) := std_ulogic_vector(softmax_div_by_sum(unsigned(word(23 downto 16)), inverted_sum));
    r(31 downto 24) := std_ulogic_vector(softmax_div_by_sum(unsigned(word(31 downto 24)), inverted_sum));
    return r;
  end function;

end package body;
