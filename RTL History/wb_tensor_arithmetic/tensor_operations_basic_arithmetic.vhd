library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Package declaration: Function prototypes
package tensor_operations_basic_arithmetic is
  
  --Operation code constants
  constant OP_ADD : std_ulogic_vector(4 downto 0) := "00000";  --R = A + B + C
  constant OP_SUB : std_ulogic_vector(4 downto 0) := "00001";  --R = A - B - C
  --TODO: Add similar codes in the future   
  
  --Function prototypes
  function add_packed_int8(a,b,c: std_ulogic_vector(31 downto 0)) --The function takes in 3 32-bit input words. One word from each tensor
    return std_ulogic_vector;
  
  function sub_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) --The function takes in 3 32-bit input words. One word from each tensor
    return std_ulogic_vector;
  

end package tensor_operations_basic_arithmetic;

--Function implementations
package body tensor_operations_basic_arithmetic is

  function add_packed_int8(a,b,c: std_ulogic_vector(31 downto 0)) --The function takes in 3 32-bit input words. One word from each tensor
    return std_ulogic_vector is
    variable result: std_ulogic_vector(31 downto 0);    --Result returned is a 32-bit word
    variable sum0, sum1, sum2, sum3 : signed(9 downto 0);  --Each sum is 10 bits. The extra buts help in handling overflow
  begin
    --Add each byte separately
    --Convert each byte to a signed 10 bit number
    --Byte 1 in word: bits[7:0]
    --Byte 2 in word: bits[15:8]
    --Byte 3 in word: bits[23:16]
    --Byte 4 in word: bits[31:24]
    --":=" is used for variable assignment in a procedure
    sum0:= resize(signed(a(7 downto 0)),10) + 
            resize(signed(b(7 downto 0)),10) + 
            resize(signed(c(7 downto 0)),10);
    sum1:= resize(signed(a(15 downto 8)),10) + 
            resize(signed(b(15 downto 8)),10) + 
            resize(signed(c(15 downto 8)),10);
    sum2:= resize(signed(a(23 downto 16)),10) + 
            resize(signed(b(23 downto 16)),10) + 
            resize(signed(c(23 downto 16)),10);
    sum3:= resize(signed(a(31 downto 24)),10) + 
            resize(signed(b(31 downto 24)),10) + 
            resize(signed(c(31 downto 24)),10);

    --Resize numbers to int8 range (-128 to 127)
    if(sum0>127) then
      result(7 downto 0):= std_ulogic_vector(to_signed(127, 8));
    elsif(sum0 < -128) then
      result(7 downto 0):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(7 downto 0):= std_ulogic_vector(sum0(7 downto 0));
    end if;
    
    --Repeat resizing for the other 3 sums
    if(sum1>127) then
      result(15 downto 8):= std_ulogic_vector(to_signed(127, 8));
    elsif(sum1<-128) then
      result(15 downto 8):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(15 downto 8):= std_ulogic_vector(sum1(7 downto 0));
    end if;

    if(sum2>127) then
      result(23 downto 16):= std_ulogic_vector(to_signed(127, 8));
    elsif(sum2<-128) then
      result(23 downto 16):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(23 downto 16):= std_ulogic_vector(sum2(7 downto 0));
    end if;

    if(sum3 > 127) then
      result(31 downto 24):= std_ulogic_vector(to_signed(127, 8));
    elsif(sum3 < -128) then
      result(31 downto 24):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(31 downto 24):= std_ulogic_vector(sum3(7 downto 0));
    end if;

    return result; --Return the word sozed result
  end function;

    function sub_packed_int8(a, b, c: std_ulogic_vector(31 downto 0)) --The function takes in 3 32-bit input words. One word from each tensor
      return std_ulogic_vector is
      variable result: std_ulogic_vector(31 downto 0);      --Result returned is a 32-bit word
      variable diff0, diff1, diff2, diff3 : signed(9 downto 0);     --Each sum is 10 bits. The extra buts help in handling overflow
    begin
      --Subtract each byte: A - B - C
      diff0:= resize(signed(a(7 downto 0)),10) - 
               resize(signed(b(7 downto 0)),10) - 
               resize(signed(c(7 downto 0)),10);
      diff1:= resize(signed(a(15 downto 8)),10) - 
               resize(signed(b(15 downto 8)),10) - 
               resize(signed(c(15 downto 8)),10);
      diff2:= resize(signed(a(23 downto 16)),10) - 
               resize(signed(b(23 downto 16)),10) - 
               resize(signed(c(23 downto 16)),10);
      diff3:= resize(signed(a(31 downto 24)),10) - 
               resize(signed(b(31 downto 24)),10) - 
               resize(signed(c(31 downto 24)),10);
    

    --Resize numbers to int8 range (-128 to 127)
    if(diff0>127) then
      result(7 downto 0):= std_ulogic_vector(to_signed(127, 8));
    elsif(diff0 < -128) then
      result(7 downto 0):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(7 downto 0):= std_ulogic_vector(diff0(7 downto 0));
    end if;
    
    --Repeat resizing for the other 3 sums
    if(diff1>127) then
      result(15 downto 8):= std_ulogic_vector(to_signed(127, 8));
    elsif(diff1<-128) then
      result(15 downto 8):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(15 downto 8):= std_ulogic_vector(diff1(7 downto 0));
    end if;

    if(diff2>127) then
      result(23 downto 16):= std_ulogic_vector(to_signed(127, 8));
    elsif(diff2<-128) then
      result(23 downto 16):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(23 downto 16):= std_ulogic_vector(diff2(7 downto 0));
    end if;

    if(diff3 > 127) then
      result(31 downto 24):= std_ulogic_vector(to_signed(127, 8));
    elsif(diff3 < -128) then
      result(31 downto 24):= std_ulogic_vector(to_signed(-128, 8));
    else
      result(31 downto 24):= std_ulogic_vector(diff3(7 downto 0));
    end if;
    
      return result; --Return the word sozed result
    end function;

end package body tensor_operations_basic_arithmetic;
