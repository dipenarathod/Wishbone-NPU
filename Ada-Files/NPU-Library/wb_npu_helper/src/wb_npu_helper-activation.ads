package Wb_Npu_Helper.Activation is
   --Activation Functions
   procedure Apply_ReLU_All_Words
     (N : Natural; One_Dimensional : Boolean := False);
   procedure Apply_Sigmoid_All_Words
     (N : Natural; One_Dimensional : Boolean := False);
   procedure Apply_Softmax_All_Words
     (N : Natural; One_Dimensional : Boolean := False);

   pragma Inline(Apply_ReLU_All_Words);
   pragma Inline(Apply_Sigmoid_All_Words);
   pragma Inline(Apply_Softmax_All_Words);
end Wb_Npu_Helper.Activation;
