package Wb_Npu_Helper.Conv2D is

   procedure Apply_Conv2D_All_Words
     (N                                : Natural;
      Input_Channels                   : Natural;
      Filters                          : Natural;
      Weight_Base_Index                : Natural;
      Bias_Base_Index                  : Natural;
      Zero_Point                       : Integer;
      Quantized_Multiplier             : Integer;
      Quantized_Multiplier_Right_Shift : Natural);

   pragma Inline (Apply_Conv2D_All_Words);

end Wb_Npu_Helper.Conv2D;
