pragma Warnings (Off);
pragma Ada_95;
pragma Restrictions (No_Exception_Propagation);
with System;
package ada_main is


   GNAT_Version : constant String :=
                    "GNAT Version: 14.2.0" & ASCII.NUL;
   pragma Export (C, GNAT_Version, "__gnat_version");

   GNAT_Version_Address : constant System.Address := GNAT_Version'Address;
   pragma Export (C, GNAT_Version_Address, "__gnat_version_address");

   Ada_Main_Program_Name : constant String := "_ada_final_integration_test" & ASCII.NUL;
   pragma Export (C, Ada_Main_Program_Name, "__gnat_ada_main_program_name");

   procedure adainit;
   pragma Export (C, adainit, "adainit");

   procedure main;
   pragma Export (C, main, "main");

   --  BEGIN ELABORATION ORDER
   --  ada%s
   --  interfaces%s
   --  system%s
   --  ada.exceptions%s
   --  ada.exceptions%b
   --  ada.numerics%s
   --  ada.numerics.big_numbers%s
   --  system.float_control%s
   --  system.float_control%b
   --  system.img_char%s
   --  system.img_char%b
   --  system.machine_code%s
   --  system.parameters%s
   --  system.powten_flt%s
   --  system.storage_elements%s
   --  system.secondary_stack%s
   --  system.secondary_stack%b
   --  interfaces.c%s
   --  interfaces.c%b
   --  system.text_io%s
   --  system.text_io%b
   --  system.unsigned_types%s
   --  system.fat_flt%s
   --  ada.text_io%s
   --  ada.text_io%b
   --  system.img_int%s
   --  system.img_llu%s
   --  system.img_uns%s
   --  system.img_util%s
   --  system.img_util%b
   --  system.img_flt%s
   --  neorv32%s
   --  neorv32.uart0%s
   --  neorv32_hal_config%s
   --  input_output_helper%s
   --  input_output_helper%b
   --  input_output_helper.utils%s
   --  input_output_helper.utils%b
   --  input_output_helper.debug%s
   --  input_output_helper.debug%b
   --  riscv%s
   --  riscv.csr_generic%s
   --  riscv.csr_generic%b
   --  riscv.types%s
   --  riscv.csr%s
   --  interrupts%s
   --  interrupts%b
   --  rps_gray100_savedmodelv3%s
   --  runtime_support%s
   --  runtime_support%b
   --  uart0%s
   --  uart0%b
   --  input_output_helper.time_measurements%s
   --  input_output_helper.time_measurements%b
   --  wb_npu_address_map%s
   --  wb_npu_helper%s
   --  wb_npu_helper%b
   --  wb_npu_helper.activation%s
   --  wb_npu_helper.activation%b
   --  wb_npu_helper.conv2d%s
   --  wb_npu_helper.conv2d%b
   --  wb_npu_helper.debug%s
   --  wb_npu_helper.debug%b
   --  wb_npu_helper.dense%s
   --  wb_npu_helper.dense%b
   --  wb_npu_helper.pooling%s
   --  wb_npu_helper.pooling%b
   --  wb_ov5640_address_map%s
   --  wb_ov5640_helper%s
   --  wb_ov5640_helper%b
   --  final_integration_test%b
   --  END ELABORATION ORDER

end ada_main;
