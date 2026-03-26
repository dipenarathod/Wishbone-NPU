import numpy as np
import tensorflow as tf
from pathlib import Path

# model_path="14x14_mnist_model.keras"
model_path = "breast_cancer.keras"
output_path=Path("exported_weights_q07")

ada_ads_path = output_path / "breast_cancer_test_weights.ads"
ada_package_name = "breast_cancer_test_weights"

#Input and output scales are always int8 Q0.7
lhs_scale = 1.0/128.0
lhs_zp = 0

#Dense output must also be int8 Q0.7 (so following layers stay unchanged)
result_scale = 1.0/128.0
result_zp = 0

q_min_int8 = -128
q_max_int8 = 127


def get_scale_and_zero_point(r_min, r_max):
    r_min=min(float(r_min), 0.0)    #Ensure 0 is included if all numbers are > 0
    r_max=max(float(r_max), 0.0)    #Ensure 0 is included if all numbers are < 0

    #Avoid divide by zero when calculating zerop point using scale later
    if(r_max==r_min):
        scale=1.0
        zero_point=0
        return scale, zero_point

    #S=(r_max-r_min)/(q_max-q_min)
    scale=(r_max-r_min)/float(q_max_int8-q_min_int8)

    #Zero point = q_min-(r_min/Scale)
    zero_point=int(np.round(q_min_int8-(r_min/scale)))

    #Force zero point in valid int8 range
    zero_point = np.clip(zero_point, q_min_int8, q_max_int8)

    return scale, zero_point

#Clip to int8 range
def quantize_int8(x, scale, zero_point):
    #Quantized value=round(R/S + Z)
    q=np.round(x/scale + zero_point).astype(np.int32)
    q=np.clip(q, q_min_int8, q_max_int8).astype(np.int8)
    return q


#Convert real multiplier to quantized multipler and right shifts (required to convert quatized multiplier to real multiplier)
def quantize_multiplier_smaller_than_one(real_multiplier):
    s=0
    while(real_multiplier < 0.5):
        real_multiplier *= 2.0
        s += 1

    q=int(np.round(real_multiplier * (1 << 31)))#Convert real multiplier to int32. real number * 2^31

    #quantized multiplier can't be 1 (refer to paragraphs after eqn 7 in gemmlowp's guide). +1 is outside of the int8 Q0.7 range [-1,0.9982]
    if(q == (1 << 31)): #q should != 2^31
        q //= 2
        s -= 1

    quantized_multiplier=int(q)          
    right_shift=int(s)                   
    #The quantized multiplier is a number in range [-1,1) stored in a int32 number. Tehrefore, It is left shifted by 31 bits
    return quantized_multiplier, right_shift


def write_array(f, name, arr):
    f.write(name + "\n")
    flat=arr.flatten()
    f.write(f"Length of array={len(flat)}\n")
    for i, v in enumerate(flat):
        f.write(str(int(v)))
        if(i != len(flat)-1):
            f.write(", ")
        if((i + 1) % 20 == 0):  #I tried printing 20 numbers per line in text. 20 was an arbitrary choice. 20 numbers per line look good
            f.write("\n")
    f.write("\n\n")


#Convert int to strict 8-bits for left shifting it. The 8-bits will be stored in the 32-bit word
def int_to_byte(v: int):
    return int(v) & 0xFF


#Pack 4 8-bit values in a 32-bit word
def pack_four_bytes(b0, b1, b2, b3):
    return (b0 & 0xFF) | ((b1 & 0xFF) << 8) | ((b2 & 0xFF) << 16) | ((b3 & 0xFF) << 24)

#Pack an int8 array into a 32-bit words array
def pack_int_array_to_words(arr_int8):
    flat = arr_int8.flatten()
    words = []
    for i in range(0, len(flat), 4):
        b0 = int_to_byte(flat[i])
        b1 = 0
        b2 = 0
        b3 = 0
        if(i + 1 < len(flat)):
            b1 = int_to_byte(flat[i + 1])
        if(i + 2 < len(flat)):
            b2 = int_to_byte(flat[i + 2])
        if(i + 3 < len(flat)):
            b3 = int_to_byte(flat[i + 3])
        words.append(pack_four_bytes(b0, b1, b2, b3))
    return words

#Stric 32-bit representation
def int_to_word(v):
    return int(v) & 0xFFFFFFFF

#Helper to write integer in Ada
def write_ada_int(f, name, value: int):
    f.write(f"{name} : constant Integer := {int(value)};\n")

#Helper to write Ada word array.
def write_ada_word_array(f, name, words):
    f.write(f"{name} : constant Word_Array (Natural range 0 .. {len(words)-1}) := (\n")
    if(len(words) == 1):
        f.write(f"  0 => 16#{words[0]:08X}#\n")
    else:
        for i, w in enumerate(words):
            if(i!=len(words)-1):
                sep = ","
            else:
                sep = ""
            f.write(f"16#{w:08X}#{sep}\n")
    f.write(");\n\n")
#Search (backward) through layers (up to but not including layer_index) to find
#the most recent layer with a 4D output shape (batch, height, width, channels) 
#Returns (height, width, channels) if found and height*width*channels equals the input size for the dense layer this function is called, else "None"
#Used to detect that a Dense layer's input was flattened from a conv2d or pooling layer so we can reorder the weights
#so that theu are exported as per neuron weights required by the dense implementation
def find_pre_flatten_shape(model, layer_index, expected_flat_size):
    for prev_layer in reversed(model.layers[:layer_index]): #Extract layers upto layer index
        try:    #Added this because the fake quanization lambda layer in the 28x28 test was trhowing errors. Problem was I did not the function + decorator here
            out_shape = prev_layer.output.shape
        except Exception:
            continue

        if (len(out_shape) != 4): #A flattern or dense layer
            continue
        batch, height, width, channels = out_shape
        if (height * width * channels == expected_flat_size):
            return (height, width, channels)
        
        return None
    return None

@tf.keras.utils.register_keras_serializable()
def fake_q07(x):
    x_clip = tf.clip_by_value(x, -1.0, 127.0/128.0)
    x_q = tf.round(x_clip * 128.0) / 128.0
    return x_clip + tf.stop_gradient(x_q - x_clip)

def main():
    output_path.mkdir(parents = True, exist_ok = True)
    model=tf.keras.models.load_model(model_path)
    model.summary()
    ada_file = open(ada_ads_path, "w")
    ada_file.write("with Input_Output_Helper; use Input_Output_Helper;\n\n")
    ada_file.write(f"package {ada_package_name} is\n\n")
    for layer_index, layer in enumerate(model.layers):
        
        weights=layer.get_weights()
        if(not weights):
            #Skip layers without weights
            continue

        base_name=f"layer_{layer_index}_{layer.name}"
        header_path=output_path/f"{base_name}.txt"

        with open(header_path, "w") as f:
            #Dense and conv: weights and biases both
            if(len(weights)==2):
                w_float, b_float=weights

                w_scale, w_zp=get_scale_and_zero_point(np.min(w_float), np.max(w_float))

                #Quantize weights to int8
                w_q=quantize_int8(w_float, w_scale, w_zp)
                if (len(w_q.shape) == 4):#Conv2D layer (height, width, input channels, output channels)
                    #All filter weights will be arranged sequentially so we can do one kernel at a time in VHDL
                    #9 weights of kernel 1, then kernel 2, etc for one filter. And then so on for all filters
                    w_q = w_q.transpose(3, 2, 0, 1) #(output channels, input channels, height, width)
                else: #Dense layer
                    inputs, neurons = w_q.shape
                    shape = find_pre_flatten_shape(model, layer_index, inputs)
                    if (shape is not None):
                        height, width, channels = shape
                        f.write(f"# Dense input reordered({height},{width},{channels}) to (neurons, channels, height, width)\n")#Debug print
                        w_q = w_q.reshape(height, width, channels, neurons).transpose(3, 2, 0, 1).reshape(neurons, inputs)
                    else:
                        w_q = w_q.T #IMPORTANT bug Solved the problem
                                    #(neurons, inputs) for dense layers that did not have a preceeding 4D layer
                    #All weights for one neuron, then the next neuron, and so on
                #Quantize bias to int32 using bias_scale=lhs_scale * w_scale
                #bias is added to the accumulator, before requantization
                bias_scale=lhs_scale * w_scale
                b_q32=np.round(b_float/bias_scale).astype(np.int32)

                #Compute requantization multiplier for output:
                #real_multiplier=(lhs_scale * rhs_scale)/result_scale
                #lhs_scale=lhs_scale, rhs_scale=w_scale, result_scale=result_scale
                real_multiplier=(lhs_scale * w_scale)/result_scale

                quantized_mult, quantized_right_shift=quantize_multiplier_smaller_than_one(real_multiplier)

                #Write data to files
                f.write(f"{base_name}\n")
                f.write(f"W_scale={w_scale}\n")
                f.write(f"W_zp={w_zp}\n")
                f.write(f"bias_scale = lhs_scale * W_scale = {bias_scale}\n")
                f.write(f"real multiplier = (lhs_scale * W_scale)/result_scale = {real_multiplier}\n")
                f.write(f"quantized mult = {quantized_mult}\n")
                f.write(f"quantized right shift (right shift) = {quantized_right_shift}\n")
                f.write("\n")

                #Export arrays
                write_array(f, f"{base_name}_weights_int8", w_q.astype(np.int8))
                write_array(f, f"{base_name}_bias_int32", b_q32.astype(np.int32))

                w_words = pack_int_array_to_words(w_q.astype(np.int8))
                b_words = [int_to_word(v) for v in b_q32.flatten()]
                
                prefix = base_name
                write_ada_int(ada_file, f"{prefix}_WZP", int(w_zp))
                write_ada_int(ada_file, f"{prefix}_Quantized_Multiplier", int(quantized_mult))
                write_ada_int(ada_file, f"{prefix}_Quantized_Right_Shift", int(quantized_right_shift))
                ada_file.write("\n")

                write_ada_word_array(ada_file, f"{prefix}_Weights_Words", w_words)
                write_ada_word_array(ada_file, f"{prefix}_Bias_Words", b_words)
            else:
                for p_index, p_float in enumerate(weights):
                    p_scale, p_zp = get_scale_and_zero_point(np.min(p_float), np.max(p_float))
                    p_q = quantize_int8(p_float, p_scale, p_zp)
                    f.write(f"{base_name}_p{p_index}\n")
                    f.write(f"scale={p_scale}\n")
                    f.write(f"ZERO_POINT={p_zp}\n\n")
                    write_array(f, f"{base_name}_p{p_index}_int8", p_q.astype(np.int8))
    ada_file.write(f"end {ada_package_name};\n")
    ada_file.close()


if(__name__ == "__main__"):
    main()
