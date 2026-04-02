package Wb_Npu_Helper.pooling is

   --2x2 pooling across the entire N×N tensor (stride 2, no padding)
   --Produces an (N/2)×(N/2) result into R
   procedure Apply_MaxPool_2x2_All_Words
     (N : Natural; Base : Natural := 0; Out_Index : Natural := 0);
   procedure Apply_AvgPool_2x2_All_words
     (N : Natural; Base : Natural := 0; Out_Index : Natural := 0);
   procedure Apply_MaxPool_Multi_Channel (N : Natural; Number_Of_Output_Channels: Natural);
   procedure Apply_AvgPool_Multi_Channel (N : Natural; Number_Of_Output_Channels: Natural);

   pragma Inline (Apply_MaxPool_2x2_All_Words);
   pragma Inline (Apply_AvgPool_2x2_All_words);
   pragma Inline (Apply_MaxPool_Multi_Channel);
   pragma Inline (Apply_AvgPool_Multi_Channel);
end Wb_Npu_Helper.pooling;