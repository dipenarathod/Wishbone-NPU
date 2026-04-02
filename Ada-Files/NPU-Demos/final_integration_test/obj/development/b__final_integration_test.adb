pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (ada_main, Spec_File_Name => "b__final_integration_test.ads");
pragma Source_File_Name (ada_main, Body_File_Name => "b__final_integration_test.adb");
pragma Suppress (Overflow_Check);

package body ada_main is

   E05 : Short_Integer; pragma Import (Ada, E05, "ada__text_io_E");
   E09 : Short_Integer; pragma Import (Ada, E09, "input_output_helper_E");
   E15 : Short_Integer; pragma Import (Ada, E15, "input_output_helper__utils_E");
   E13 : Short_Integer; pragma Import (Ada, E13, "input_output_helper__debug_E");
   E37 : Short_Integer; pragma Import (Ada, E37, "riscv__csr_generic_E");
   E54 : Short_Integer; pragma Import (Ada, E54, "interrupts_E");
   E52 : Short_Integer; pragma Import (Ada, E52, "runtime_support_E");
   E40 : Short_Integer; pragma Import (Ada, E40, "uart0_E");
   E30 : Short_Integer; pragma Import (Ada, E30, "input_output_helper__time_measurements_E");
   E58 : Short_Integer; pragma Import (Ada, E58, "wb_npu_helper_E");
   E60 : Short_Integer; pragma Import (Ada, E60, "wb_npu_helper__activation_E");
   E62 : Short_Integer; pragma Import (Ada, E62, "wb_npu_helper__conv2d_E");
   E64 : Short_Integer; pragma Import (Ada, E64, "wb_npu_helper__debug_E");
   E66 : Short_Integer; pragma Import (Ada, E66, "wb_npu_helper__dense_E");
   E68 : Short_Integer; pragma Import (Ada, E68, "wb_npu_helper__pooling_E");
   E71 : Short_Integer; pragma Import (Ada, E71, "wb_ov5640_helper_E");


   procedure adainit is
   begin
      null;

      Ada.Text_Io'Elab_Body;
      E05 := E05 + 1;
      E09 := E09 + 1;
      E15 := E15 + 1;
      E13 := E13 + 1;
      E37 := E37 + 1;
      Interrupts'Elab_Body;
      E54 := E54 + 1;
      E52 := E52 + 1;
      E40 := E40 + 1;
      E30 := E30 + 1;
      E58 := E58 + 1;
      E60 := E60 + 1;
      E62 := E62 + 1;
      E64 := E64 + 1;
      E66 := E66 + 1;
      E68 := E68 + 1;
      E71 := E71 + 1;
   end adainit;

   procedure Ada_Main_Program;
   pragma Import (Ada, Ada_Main_Program, "_ada_final_integration_test");

   procedure main is
      Ensure_Reference : aliased System.Address := Ada_Main_Program_Name'Address;
      pragma Volatile (Ensure_Reference);

   begin
      adainit;
      Ada_Main_Program;
   end;

--  BEGIN Object file/option list
   --   /home/dipen/Downloads/neorv32-halv3/final_integration_test/obj/development/rps_gray100_savedmodelv3.o
   --   /home/dipen/Downloads/neorv32-halv3/final_integration_test/obj/development/runtime_support.o
   --   /home/dipen/Downloads/neorv32-halv3/final_integration_test/obj/development/final_integration_test.o
   --   -L/home/dipen/Downloads/neorv32-halv3/final_integration_test/obj/development/
   --   -L/home/dipen/Downloads/neorv32-halv3/final_integration_test/obj/development/
   --   -L/home/dipen/.local/share/alire/builds/bare_runtime_14.0.0_095db6f0/282b01b920f0d5bb2bac604ac6d9e811f26d175144bc99af963e0381e797ee94/adalib/
   --   -L/home/dipen/Downloads/neorv32-halv3/input_output_helper/lib/
   --   -L/home/dipen/Downloads/neorv32-halv3/lib/
   --   -L/home/dipen/Downloads/neorv32-halv3/wb_npu_helper/lib/
   --   -L/home/dipen/Downloads/neorv32-halv3/wb_ov5640_helper/lib/
   --   -static
   --   -lgnat
--  END Object file/option list   

end ada_main;
