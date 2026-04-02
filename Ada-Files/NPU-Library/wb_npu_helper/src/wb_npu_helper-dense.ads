package Wb_Npu_Helper.Dense is

   --Dense function
   procedure Apply_Dense_All_Words
     (Inputs                           : Natural;
      Neurons                          : Natural;
      Weight_Base_Index                : Natural;
      Bias_Base_Index                  : Natural;
      Zero_Point                       : Integer;
      Quantized_Multiplier             : Integer;
      Quantized_Multiplier_Right_Shift : Natural);
   
   pragma Inline(Apply_Dense_All_Words);
end Wb_Npu_Helper.Dense;
