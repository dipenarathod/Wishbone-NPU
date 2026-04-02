with wb_npu_address_map; use wb_npu_address_map;

package body Wb_Npu_Helper.Conv2D is

procedure Apply_Conv2D_All_Words
  (N                               : Natural;
   Input_Channels                   : Natural;
   Filters                          : Natural;
   Weight_Base_Index                : Natural;
   Bias_Base_Index                  : Natural;
   Zero_Point                       : Integer;
   Quantized_Multiplier             : Integer;
   Quantized_Multiplier_Right_Shift : Natural)
is
begin
   Set_Dim (N);
   Set_N_Inputs (Input_Channels);
   Set_N_Outputs (Filters);
   Set_Weight_Base_Index (Weight_Base_Index);
   Set_Bias_Base_Index (Bias_Base_Index);
   Set_Zero_Point (Zero_Point);
   Set_Quantized_Multiplier_Register (Quantized_Multiplier);
   Set_Quantized_Multiplier_Right_Shift_Register (Quantized_Multiplier_Right_Shift);
   Set_Word_Index (0);  
   Set_Out_Index (0); 
   Perform_Conv2D;
   Wait_While_Busy;
   Write_Reg (CTRL_Addr, 0);
end Apply_Conv2D_All_Words;

end Wb_Npu_Helper.Conv2D;
