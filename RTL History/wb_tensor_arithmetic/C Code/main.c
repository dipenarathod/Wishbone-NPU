
#include <neorv32.h>
#define TENSOR_PERIPHERAL_BASE  0x90000000UL

//#define LED_ADDR                (TENSOR_PERIPHERAL_BASE + 0x0000)
//#define BUTTON_ADDR             (TENSOR_PERIPHERAL_BASE + 0x0004)
#define CTRL_REG_ADDR           (TENSOR_PERIPHERAL_BASE + 0x0008)
#define STATUS_REG_ADDR         (TENSOR_PERIPHERAL_BASE + 0x000C)
#define DIM_REG_ADDR            (TENSOR_PERIPHERAL_BASE + 0x0010)

#define TENSOR_A_BASE           (TENSOR_PERIPHERAL_BASE + 0x1000)
#define TENSOR_B_BASE           (TENSOR_PERIPHERAL_BASE + 0x2000)
#define TENSOR_C_BASE           (TENSOR_PERIPHERAL_BASE + 0x3000)
#define TENSOR_R_BASE           (TENSOR_PERIPHERAL_BASE + 0x4000)

//Control register bits
#define CTRL_START_BIT          (1<<0)
#define CTRL_OP_ADD             (0x0<<1)  //Add=00000
#define CTRL_OP_SUB             (0x1<<1)  //Subtract=00001

//Status register bits
#define STATUS_BUSY             (1<<0)
#define STATUS_DONE             (1<<1)

//Matrix dimensions
#define ROWS 50
#define COLS 50
#define MATRIX_SIZE (ROWS * COLS)

#define BAUD_RATE 19200

void write_matrix_to_peripheral(const int8_t* matrix, uint32_t base_addr, uint32_t size) {
    uint32_t* dest = (uint32_t*)base_addr;
    uint32_t num_words = (size + 3) / 4;  //Round up to nearest word
    //Transfer data - 4 int8 can be fit into one int32
    for (uint32_t i=0;i<num_words;i++) {
        uint32_t word=0;
        for (uint32_t j=0;j<4;j++) {
            uint32_t index=i*4+j;
            if (index<size) {
                word|=((uint32_t)(matrix[index]&0xFF))<<(j*8);
                //matrix[index]&0xFF gives the lower 8 bits of the number
                //Necesary because converting to int32 causes the sign bit to be added
                //j*8 = 0, 8, 16, 24 = amount of bits to be shifted
            }
        }
        dest[i]=word;
    }
}

void read_matrix_from_peripheral(int8_t* matrix, uint32_t base_addr, uint32_t size) {
    uint32_t* src=(uint32_t*)base_addr;
    uint32_t num_words=(size+3)/4;

    //Read and unpack data
    for (uint32_t i=0;i<num_words;i++) {
        uint32_t word=src[i];
        for (uint32_t j=0;j<4;j++) {
            uint32_t index=i*4+j;
            if (index<size) {
                matrix[index]=(int8_t)((word >> (j * 8)) & 0xFF);
                //Just reversed the logic of packing
            }
        }
    }
}

int main() {
    neorv32_uart0_setup(BAUD_RATE, 0);
    neorv32_uart0_printf("NEORV32 Tensor Peripheral Test");
    //Allocate matrices - Static so we only share one copy. Should avoid overflow
    static int8_t matrix_A[MATRIX_SIZE];
    static int8_t matrix_B[MATRIX_SIZE];
    static int8_t matrix_C[MATRIX_SIZE];
    static int8_t matrix_R[MATRIX_SIZE];

    //Initialize test matrices with sample data
    for (uint32_t i=0;i<MATRIX_SIZE;i++) {
        matrix_A[i]= (int8_t)(i%100);       //A has values from 0 to 100
        matrix_B[i]= (int8_t)((i%100)-50); //B has values -50 to 49
        matrix_C[i]= (int8_t)((i%100)+20); //C has values 20 to 119
    }

    write_matrix_to_peripheral(matrix_A, TENSOR_A_BASE, MATRIX_SIZE);
    write_matrix_to_peripheral(matrix_B, TENSOR_B_BASE, MATRIX_SIZE);
    write_matrix_to_peripheral(matrix_C, TENSOR_C_BASE, MATRIX_SIZE);

    //Set matrix dimensions
    *((volatile uint32_t*)DIM_REG_ADDR) = ROWS;

    neorv32_uart0_printf("Test addition\n");
    *((volatile uint32_t*)CTRL_REG_ADDR)= CTRL_OP_ADD | CTRL_START_BIT;

    //Wait for completion
    while (*((volatile uint32_t*)STATUS_REG_ADDR) & STATUS_BUSY) {
    }


    neorv32_uart0_printf("Addition completed\n");

    //Read addition result back
    read_matrix_from_peripheral(matrix_R, TENSOR_R_BASE, MATRIX_SIZE);

    //Print some results
    neorv32_uart0_printf("Results\n");
    for (uint32_t i=0;i<10;i++) {
        neorv32_uart0_printf("Element[%d]: %d + %d + %d = %d\n",
                             i, matrix_A[i], matrix_B[i], matrix_C[i], matrix_R[i]);
    }
    neorv32_uart0_printf("Test completed!\n");

    return 0;
}
