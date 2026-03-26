#include <neorv32.h>

// Custom peripheral addresses - XBUS safe range
#define LED_ADDRESS    (*((volatile uint32_t*) 0x90000000))
#define BUTTON_ADDRESS (*((volatile uint32_t*) 0x90000004))

void led_write(uint8_t value);
uint8_t button_read(void);

int main(void) {
  
  //neorv32_rte_setup();
  neorv32_uart0_setup(19200, 0);

  neorv32_uart0_puts("\n<<< NEORV32 XBUS Peripheral Test >>>\n\n");
  neorv32_uart0_puts("LED Address:    0x90000000\n");
  neorv32_uart0_puts("Button Address: 0x90000004\n\n");

  // Test 1: LED Pattern Test
  neorv32_uart0_puts("Test 1: Binary counter on LEDs\n\n");
  
  for (int i = 0; i < 256; i++) {
    led_write((uint8_t)i);
    
    // Simple delay
    for (volatile uint32_t d = 0; d < 500000; d++);
  }

  // Test 2: Button to LED mapping
  neorv32_uart0_puts("Test 2: Press buttons - state shown on LEDs\n");
  neorv32_uart0_puts("Running continuously...\n\n");
  
  uint8_t button_state, last_state = 0;
  
  while (1) {
    button_state = button_read();
    
    // Display button state on LEDs
    led_write(button_state);
    
    // Print when changed
    if (button_state != last_state) {
      neorv32_uart0_puts("Buttons: 0b");
      for (int j = 2; j >= 0; j--) {
        neorv32_uart0_putc((button_state & (1 << j)) ? '1' : '0');
      }
      neorv32_uart0_puts(" -> LEDs updated\n");
      last_state = button_state;
    }
    
    // Debounce delay
    for (volatile uint32_t d = 0; d < 50000; d++);
  }

  return 0;
}

void led_write(uint8_t value) {
  LED_ADDRESS = (uint32_t)value;
}

uint8_t button_read(void) {
  return (uint8_t)(BUTTON_ADDRESS & 0x07);
}

