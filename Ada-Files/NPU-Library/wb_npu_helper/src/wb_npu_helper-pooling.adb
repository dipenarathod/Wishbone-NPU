with wb_npu_address_map; use wb_npu_address_map;
package body Wb_Npu_Helper.pooling is

   --2x2 max pooling over entire tensor
   --Produces (N/2) x (N/2) outputs in R
   procedure Apply_MaxPool_2x2_All_Words
     (N : Natural; Base : Natural := 0; Out_Index : Natural := 0)
   is
      Out_N : constant Natural := N / 2;  --floor division for odd N
   begin
      Set_Dim (N);   --Value in DIM is required by the VHDL
      Set_Pool_Base_Index (Base);
      Set_Out_Index (Out_Index);
      Perform_Max_Pool;
      Wait_While_Busy;
      Write_Reg (CTRL_Addr, 0); --De-assert start
   end Apply_MaxPool_2x2_All_Words;

   --2x2 average pooling over entire tensor
   --Produces (N/2) x (N/2) outputs in R
   procedure Apply_AvgPool_2x2_All_Words
     (N : Natural; Base : Natural := 0; Out_Index : Natural := 0)
   is
      Out_N : constant Natural := N / 2;  --floor division for odd N
   begin
      Set_Dim (N);
      Set_Pool_Base_Index (Base);
      Set_Out_Index (Out_Index);
      Perform_Avg_Pool;
      Wait_While_Busy;
      Write_Reg (CTRL_Addr, 0); --De-assert start

   end Apply_AvgPool_2x2_All_Words;

   procedure Apply_AvgPool_Multi_Channel
     (N : Natural; Number_Of_Output_Channels : Natural)
   is
      Out_N            : constant Natural := N / 2;
      In_Channel_Size  : constant Natural := N * N;
      Out_Channel_Size : constant Natural := Out_N * Out_N;
   begin
      --Set_Dim (N);
      for i in 0 .. Number_Of_Output_Channels - 1 loop
         Apply_AvgPool_2x2_All_Words(N, i * In_Channel_Size, i * Out_Channel_Size);
      end loop;
   end Apply_AvgPool_Multi_Channel;

   procedure Apply_MaxPool_Multi_Channel
     (N : Natural; Number_Of_Output_Channels : Natural)
   is
      Out_N            : constant Natural := N / 2;
      In_Channel_Size  : constant Natural := N * N;
      Out_Channel_Size : constant Natural := Out_N * Out_N;
   begin
      --Set_Dim (N);
      for i in 0 .. Number_Of_Output_Channels - 1 loop
         Apply_MaxPool_2x2_All_Words(N, i * In_Channel_Size, i * Out_Channel_Size);
      end loop;
   end Apply_MaxPool_Multi_Channel;

end Wb_Npu_Helper.pooling;
