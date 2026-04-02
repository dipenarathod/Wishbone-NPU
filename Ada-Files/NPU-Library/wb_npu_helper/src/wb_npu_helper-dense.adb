with wb_npu_address_map; use wb_npu_address_map;
package body Wb_Npu_Helper.Dense is

   --Dense function
   --Computes Neurons outputs (1 output per NPU command) and stores them in R
   procedure Apply_Dense_All_Words
     (Inputs                           : Natural;
      Neurons                          : Natural;
      Weight_Base_Index                : Natural;
      Bias_Base_Index                  : Natural;
      Zero_Point                       : Integer;
      Quantized_Multiplier             : Integer;
      Quantized_Multiplier_Right_Shift : Natural)
   is
      Input_Base_Index : constant Natural := 0;

      W_Base  : Natural;
      B_Index : Natural;
   begin
      Set_N_Inputs (Inputs); --Set number of inputs to dense layer
      Set_N_Outputs (Neurons);

      Set_Zero_Point (Zero_Point);
      Set_Quantized_Multiplier_Register (Quantized_Multiplier);
      Set_Quantized_Multiplier_Right_Shift_Register
        (Quantized_Multiplier_Right_Shift);

      Set_Word_Index (Input_Base_Index);
      Set_Weight_Base_Index (Weight_Base_Index);
      Set_Bias_Base_Index (Bias_Base_Index);
      Set_Out_Index (0);

      Perform_Dense;
      Wait_While_Busy;
      Write_Reg (CTRL_Addr, 0);
   end Apply_Dense_All_Words;

end Wb_Npu_Helper.Dense;
