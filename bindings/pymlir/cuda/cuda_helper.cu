//===----------------------------------------------------------------------===//
//
// Copyright (C) 2022 Sophgo Technologies Inc.  All rights reserved.
//
// TPU-MLIR is licensed under the 2-Clause BSD License except for the
// third-party components.
//
//===----------------------------------------------------------------------===//

#include "cuda_helper.h"
#include "stdio.h"

#define CUDA_BLOCK_SIZE 256
#define CUDA_NUM_BLOCKS(n) ((n + CUDA_BLOCK_SIZE - 1) / CUDA_BLOCK_SIZE)

template <typename T> __device__ T kernelInt(float data, cuda_rmode_t rmode) {
  switch (rmode) {
  case CUDA_HALF_AWAY_FROM_ZERO:
    data = roundf(data);
    break;
  case CUDA_HALF_UP:
    data = floor(data + 0.5f);
    break;
  case CUDA_TOWARDS_ZERO:
    data = truncf(data);
    break;
  case CUDA_HALF_TO_EVEN:
    float fraction, integer;
    float abs_v = std::abs(data);
    fraction = std::modf(abs_v, &integer);
    int32_t i32_val = (int32_t)integer;
    if (fraction > 0.5) {
      i32_val = i32_val + 1;
    } else if (fraction == 0.5) {
      if (i32_val & 0x01) {
        i32_val = i32_val + 1;
      }
    }
    if (data < 0) {
      i32_val = -i32_val;
    }
    data = static_cast<float>(i32_val);
    break;
  }
  if (std::is_same<T, int8_t>::value) {
    data = fmaxf(-128.0f, fminf(127.0f, data));
  } else if (std::is_same<T, uint8_t>::value) {
    data = fmaxf(0.0f, fminf(255.0f, data));
  }
  return static_cast<T>(data);
}

__global__ void kernelF32ToInt8(float *input, void *output, float scale,
                                int size, bool sign, cuda_rmode_t rmode) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    float value = input[idx] * scale;
    if (sign) {
      static_cast<int8_t *>(output)[idx] = kernelInt<int8_t>(value, rmode);
    } else {
      static_cast<uint8_t *>(output)[idx] = kernelInt<uint8_t>(value, rmode);
    }
  }
}

void cudaF32ToInt8(void *input, void *output, float scale, int size, bool sign,
                   cuda_rmode_t rmode) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  kernelF32ToInt8<<<num_blocks, block_size>>>((float *)input, output, scale,
                                              size, sign, rmode);
}

struct bfloat16 {
  uint16_t value;

  __device__ bfloat16() : value(0) {}
  __device__ bfloat16(float val, bool half_up = false) {
    if (half_up) {
      uint32_t u32_val = *((uint32_t *)(&val));
      uint32_t lsb = (u32_val >> 16) & 1;
      u32_val += (0x7fff + lsb);
      value = ((uint16_t *)(&u32_val))[1];
      /* HW behavior */
      // infinity set to max finite positive value
      value = ((value & 0x7f80) == 0x7f80) ? 0x7f7f : value;
    } else {
      value = ((uint16_t *)(&val))[1];
    }
  }

  __device__ operator float() const {
    unsigned int expanded = value << 16;
    return *reinterpret_cast<float *>(&expanded);
  }
};

__device__ bfloat16 kernelBF16Mul(bfloat16 a, bfloat16 b) {
  float af = static_cast<float>(a);
  float bf = static_cast<float>(b);
  return bfloat16(af * bf, true);
}

__global__ void kernelCVScaleToF32(int8_t *input, float *output, float scale,
                                   int size) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    // Step 1: Convert int8 to FP32
    float intermediate = static_cast<float>(input[idx]);

    // Step 2: Multiply input by BF16 scale
    bfloat16 bf16_result =
        kernelBF16Mul(bfloat16(intermediate), bfloat16(scale));

    // Step 3: Convert BF16 back to FP32
    output[idx] = static_cast<float>(bf16_result);
  }
}

void cudaCVScaleToF32(void *input, void *output, float scale, int size) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  kernelCVScaleToF32<<<num_blocks, block_size>>>((int8_t *)input,
                                                 (float *)output, scale, size);
}

__global__ void kernelInt8ToF32(void *input, float *output, float scale,
                                int size, bool sign) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    // Convert int8 to float32 and scale
    if (sign) {
      output[idx] = static_cast<float>(((int8_t *)input)[idx]) * scale;
    } else {
      output[idx] = static_cast<float>(((uint8_t *)input)[idx]) * scale;
    }
  }
}

void cudaInt8ToF32(void *input, void *output, float scale, int size,
                   bool sign) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  kernelInt8ToF32<<<num_blocks, block_size>>>((int8_t *)input, (float *)output,
                                              scale, size, sign);
}

__global__ void kernelCVQuantInt8(float *input, int8_t *output, float scale,
                                  int size) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    auto out_bf16 = kernelBF16Mul(bfloat16(input[idx]), bfloat16(scale));
    auto out_f32 = static_cast<float>(out_bf16);
    output[idx] = kernelInt<int8_t>(out_f32, CUDA_HALF_TO_EVEN);
  }
}

void cudaCVQuantInt8(void *input, void *output, float scale, int size) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  kernelCVQuantInt8<<<num_blocks, block_size>>>((float *)input,
                                                (int8_t *)output, scale, size);
}

__global__ void kernelAddInt8(int8_t *a, int8_t *b, int8_t *out, int32_t mul0,
                              int32_t mul1, int shift, int size) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    int32_t temp = (int32_t)a[idx] * mul0 + (int32_t)b[idx] * mul1;
    temp = (temp + (1 << (shift - 1))) >> shift;
    temp = max(-128, min(127, temp));
    out[idx] = static_cast<int8_t>(temp);
  }
}

void cudaAddInt8(void *input0, void *input1, void *output, int mul0, int mul1,
                 int shift, int size) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  kernelAddInt8<<<num_blocks, block_size>>>((int8_t *)input0, (int8_t *)input1,
                                            (int8_t *)output, mul0, mul1, shift,
                                            size);
}

__global__ void kernelAddInt8(int8_t *a, int8_t *b, void *out, int32_t mul0,
                              int32_t mul1, int shift0, int shift1, int size,
                              bool sign) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    int32_t a_data = (int32_t)a[idx] * mul0;
    a_data = (a_data + (1 << (shift0 - 1))) >> shift0;
    a_data = max(-128, min(127, a_data));
    int32_t b_data = (int32_t)b[idx] * mul1;
    b_data = (b_data + (1 << (shift1 - 1))) >> shift1;
    b_data = max(-128, min(127, b_data));
    a_data = a_data + b_data;
    if (sign) {
      a_data = max(-128, min(127, a_data));
      static_cast<int8_t *>(out)[idx] = static_cast<int8_t>(a_data);
    } else {
      a_data = max(0, min(255, a_data));
      static_cast<uint8_t *>(out)[idx] = static_cast<uint8_t>(a_data);
    }
  }
}

void cudaAddInt8(void *input0, void *input1, void *output, int mul0, int mul1,
                 int shift0, int shift1, int size, bool sign) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  kernelAddInt8<<<num_blocks, block_size>>>((int8_t *)input0, (int8_t *)input1,
                                            output, mul0, mul1, shift0, shift1,
                                            size, sign);
}

__device__ void kernelCopyElement(void *src, int sidx, void *dst, int didx,
                                  int tbytes) {
  switch (tbytes) {
  case 1:
    static_cast<uint8_t *>(dst)[didx] = static_cast<uint8_t *>(src)[sidx];
    break;
  case 2:
    static_cast<uint16_t *>(dst)[didx] = static_cast<uint16_t *>(src)[sidx];
    break;
  case 4:
    static_cast<uint32_t *>(dst)[didx] = static_cast<uint32_t *>(src)[sidx];
    break;
  default:
    break;
  }
}

__global__ void kernelPermute4D(void *input, void *output, int n, int c, int h,
                                int w, int o0, int o1, int o2, int o3,
                                int tbytes) {
  int oldIdx = blockIdx.x * blockDim.x + threadIdx.x;

  if (oldIdx < n * c * h * w) {
    int dims[4] = {n, c, h, w};
    int newDims[4] = {dims[o0], dims[o1], dims[o2], dims[o3]};
    int ind[4];
    ind[0] = oldIdx / (c * h * w);             // n index
    ind[1] = (oldIdx % (c * h * w)) / (h * w); // c index
    ind[2] = (oldIdx % (h * w)) / w;           // h index
    ind[3] = oldIdx % w;                       // w index
    int newInd[4] = {ind[o0], ind[o1], ind[o2], ind[o3]};
    int newIdx =
        ((newInd[0] * newDims[1] + newInd[1]) * newDims[2] + newInd[2]) *
            newDims[3] +
        newInd[3];
    kernelCopyElement(input, oldIdx, output, newIdx, tbytes);
  }
}

void cudaPermute4D(void *src, void *dst, int n, int c, int h, int w, int o0,
                   int o1, int o2, int o3, int tbytes) {
  int num = n * c * h * w;
  int num_blocks = CUDA_NUM_BLOCKS(num);
  int block_size = CUDA_BLOCK_SIZE;
  kernelPermute4D<<<num_blocks, block_size>>>(src, dst, n, c, h, w, o0, o1, o2,
                                              o3, tbytes);
}

__global__ void kernelCopyAxis(void *src, void *dst, int outer_dim,
                               int axis_dim, int inner_dim, int offset, int num,
                               int tbytes) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  int total = outer_dim * num * inner_dim;
  if (idx < total) {
    int out_idx = idx / (num * inner_dim);
    int axis_idx = (idx % (num * inner_dim)) / inner_dim;
    int inner_idx = idx % inner_dim;
    int dstIdx = out_idx * axis_dim * inner_dim +
                 (axis_idx + offset) * inner_dim + inner_idx;
    kernelCopyElement(src, idx, dst, dstIdx, tbytes);
  }
}

void cudaCopyAxis(void *src, void *dst, int outer_dim, int axis_dim,
                  int inner_dim, int offset, int num, int tbytes) {
  int total = outer_dim * num * inner_dim;
  int num_blocks = CUDA_NUM_BLOCKS(total);
  int block_size = CUDA_BLOCK_SIZE;
  kernelCopyAxis<<<num_blocks, block_size>>>(src, dst, outer_dim, axis_dim,
                                             inner_dim, offset, num, tbytes);
}

__global__ void kernelMatMulF32(float *A, float *B, float *C, int m, int k,
                                int n) {
  int row = blockIdx.y * blockDim.y + threadIdx.y;
  int col = blockIdx.x * blockDim.x + threadIdx.x;

  if (row < m && col < n) {
    float sum = 0.0;
    for (int i = 0; i < k; i++) {
      sum += A[row * k + i] * B[i * n + col];
    }
    C[row * n + col] = sum;
  }
}

void cudaMatMulF32(void *input, void *right, void *output, int m, int k,
                   int n) {
  // Dimensions for blocks and grid
  dim3 threadsPerBlock(16, 16);
  dim3 blocksPerGrid((n + threadsPerBlock.x - 1) / threadsPerBlock.x,
                     (m + threadsPerBlock.y - 1) / threadsPerBlock.y);
  kernelMatMulF32<<<blocksPerGrid, threadsPerBlock>>>(
      (float *)input, (float *)right, (float *)output, m, k, n);
}

__global__ void kernelConvInt8(int8_t *input, int8_t *filter, int32_t *bias,
                               int8_t *output, int32_t *multipliers,
                               int32_t *shifts, int n, int ic, int ih, int iw,
                               int oc, int kh, int kw, int stride_h,
                               int stride_w, int pad_h, int pad_w) {
  int ox = blockIdx.x * blockDim.x + threadIdx.x;
  int oy = blockIdx.y * blockDim.y + threadIdx.y;
  int oz = blockIdx.z * blockDim.z + threadIdx.z;

  if (ox < (iw - kw + 2 * pad_w) / stride_w + 1 &&
      oy < (ih - kh + 2 * pad_h) / stride_h + 1 && oz < oc) {
    int32_t sum = 0;

    for (int c = 0; c < ic; c++) {
      for (int p = 0; p < kh; p++) {
        for (int q = 0; q < kw; q++) {
          int ix = ox * stride_w + q - pad_w;
          int iy = oy * stride_h + p - pad_h;

          if (ix >= 0 && ix < iw && iy >= 0 && iy < ih) {
            sum += input[((n * ic + c) * ih + iy) * iw + ix] *
                   filter[(((oz * ic + c) * kh + p) * kw + q)];
          }
        }
      }
    }
    if (bias != nullptr) {
      sum += bias[oz];
    }
    sum = ((int64_t)(sum * multipliers[oz]) >> 31) >> shifts[oz];

    output[(oz * (ih - kh + 2 * pad_h) / stride_h + 1 + oy) *
               ((iw - kw + 2 * pad_w) / stride_w + 1) +
           ox] = (int8_t)sum;
  }
}

void cudaConvInt8(void *input, void *filter, void *bias, void *output,
                  void *multipliers, void *shifts, int n, int ic, int ih,
                  int iw, int oc, int kh, int kw, int stride_h, int stride_w,
                  int pad_h, int pad_w) {
  dim3 blocks((iw + 15) / 16, (ih + 15) / 16, oc);
  dim3 threads(16, 16, 1);
  kernelConvInt8<<<blocks, threads>>>(
      (int8_t *)input, (int8_t *)filter, (int32_t *)bias, (int8_t *)output,
      (int32_t *)multipliers, (int32_t *)shifts, n, ic, ih, iw, oc, kh, kw,
      stride_h, stride_w, pad_h, pad_w);
}

__global__ void kernelRequantInt8Perchannel(int32_t *input, void *output,
                                            int32_t *multipliers,
                                            int32_t *shifts, int n, int c,
                                            int h, int w, bool out_sign,
                                            bool qdm, bool relu) {
  int x = blockIdx.x * blockDim.x + threadIdx.x;
  int y = blockIdx.y * blockDim.y + threadIdx.y;
  int z = blockIdx.z * blockDim.z + threadIdx.z;

  if (x < w && y < h && z < n) {
    for (int channel = 0; channel < c; channel++) {
      int index = z * (c * h * w) + channel * (h * w) + y * w + x;
      int32_t value;
      if (qdm == false) {
        // half up
        int64_t data = static_cast<int64_t>(input[index]) *
                       static_cast<int64_t>(multipliers[channel]);
        int64_t round = (int64_t)(1ll << (shifts[channel] - 1));
        data = (data + round) >> shifts[channel];
        value = static_cast<int32_t>(data);
      } else {

        int64_t data = static_cast<int64_t>(input[index]) *
                       static_cast<int64_t>(multipliers[channel]);
        data = (data + (1ll << 30)) >> 31;
        value = static_cast<int32_t>(data);
        // half away from zero
        int32_t offset = 1 << (shifts[channel] - 1);
        bool negative = value < 0;
        if (negative) {
          value = -value;
        }
        value = (value + offset) >> shifts[channel];
        if (negative) {
          value = -value;
        }
      }
      if (out_sign) {
        int32_t min_ = relu ? 0 : -128;
        value = max(min_, min(127, value));
        ((int8_t *)output)[index] = static_cast<int8_t>(value);
      } else {
        value = max(0, min(255, value));
        ((uint8_t *)output)[index] = static_cast<uint8_t>(value);
      }
    }
  }
}

void cudaRequantInt8Perchannel(void *input, void *output, void *multipliers,
                               void *shifts, int n, int c, int h, int w,
                               bool out_sign, bool qdm, bool relu) {
  dim3 threadsPerBlock(16, 16, 1);
  dim3 numBlocks((w + threadsPerBlock.x - 1) / threadsPerBlock.x,
                 (h + threadsPerBlock.y - 1) / threadsPerBlock.y,
                 (n + threadsPerBlock.z - 1) / threadsPerBlock.z);
  kernelRequantInt8Perchannel<<<numBlocks, threadsPerBlock>>>(
      (int32_t *)input, output, (int32_t *)multipliers, (int32_t *)shifts, n, c,
      h, w, out_sign, qdm, relu);
}

__global__ void kernelRequantInt8(int32_t *input, void *output,
                                  int32_t multiplier, int32_t shift, int num,
                                  bool out_sign, bool qdm, bool relu) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num) {
    int32_t value;
    if (qdm == false) {
      // half up
      int64_t data =
          static_cast<int64_t>(input[idx]) * static_cast<int64_t>(multiplier);
      int64_t round = 1ll << (shift - 1);
      data = (data + round) >> shift;
      value = static_cast<int32_t>(data);
    } else {
      int64_t data =
          static_cast<int64_t>(input[idx]) * static_cast<int64_t>(multiplier);
      data = (data + (1ll << 30)) >> 31;
      value = static_cast<int32_t>(data);
      // half away from zero
      int32_t offset = 1 << (shift - 1);
      bool negative = value < 0;
      if (negative) {
        value = -value;
      }
      value = (value + offset) >> shift;
      if (negative) {
        value = -value;
      }
    }
    if (out_sign) {
      int32_t min_ = relu ? 0 : -128;
      value = max(min_, min(127, value));
      ((int8_t *)output)[idx] = static_cast<int8_t>(value);
    } else {
      value = max(0, min(255, value));
      ((uint8_t *)output)[idx] = static_cast<uint8_t>(value);
    }
  }
}

void cudaRequantInt8(void *input, void *output, int32_t multiplier,
                     int32_t shift, int num, bool out_sign, bool qdm,
                     bool relu) {
  int num_blocks = CUDA_NUM_BLOCKS(num);
  int block_size = CUDA_BLOCK_SIZE;
  kernelRequantInt8<<<num_blocks, block_size>>>(
      (int32_t *)input, output, multiplier, shift, num, out_sign, qdm, relu);
}

__global__ void kernelCVMultiShiftInt8(int8_t *input, int8_t *output,
                                       int multiplier, int shift, int size) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    int32_t value = static_cast<int32_t>(input[idx]) * multiplier;
    value = (value + 1 << (shift - 1)) >> shift; // half up
    value = max(-128, min(127, value));
    output[idx] = static_cast<int8_t>(value);
  }
}

void cudaCVMultiShiftInt8(void *input, void *output, int multiplier, int shift,
                          int size) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  kernelCVMultiShiftInt8<<<num_blocks, block_size>>>(
      (int8_t *)input, (int8_t *)output, multiplier, shift, size);
}

__global__ void kernelInt32ToFloat(int32_t *input, float *output, int size) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    output[idx] = static_cast<float>(input[idx]);
  }
}

__global__ void kernelFloatToInt32(float *input, int32_t *output, int size,
                                   cuda_rmode_t rmode) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    output[idx] = kernelInt<int32_t>(input[idx], rmode);
  }
}

__global__ void kernelInt8ToFloat(int8_t *input, float *output, int size) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    output[idx] = static_cast<float>(input[idx]);
  }
}

__global__ void kernelFloatToInt8(float *input, int8_t *output, int size,
                                  cuda_rmode_t rmode) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    output[idx] = kernelInt<int8_t>(input[idx], rmode);
  }
}

__global__ void kernelUint8ToFloat(uint8_t *input, float *output, int size) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    output[idx] = static_cast<float>(input[idx]);
  }
}

__global__ void kernelFloatToUint8(float *input, uint8_t *output, int size,
                                   cuda_rmode_t rmode) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < size) {
    output[idx] = kernelInt<uint8_t>(input[idx], rmode);
  }
}

cudaError_t cudaTransform(void *src, void *dst, int size,
                          cudnnDataType_t src_type, cudnnDataType_t dst_type,
                          cuda_rmode_t rmode) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  if (src_type == CUDNN_DATA_FLOAT && dst_type == CUDNN_DATA_INT32) {
    kernelFloatToInt32<<<num_blocks, block_size>>>((float *)src, (int32_t *)dst,
                                                   size, rmode);
  } else if (src_type == CUDNN_DATA_INT32 && dst_type == CUDNN_DATA_FLOAT) {
    kernelInt32ToFloat<<<num_blocks, block_size>>>((int32_t *)src, (float *)dst,
                                                   size);
  } else if (src_type == CUDNN_DATA_FLOAT && dst_type == CUDNN_DATA_INT8) {
    kernelFloatToInt8<<<num_blocks, block_size>>>((float *)src, (int8_t *)dst,
                                                  size, rmode);
  } else if (src_type == CUDNN_DATA_INT8 && dst_type == CUDNN_DATA_FLOAT) {
    kernelInt8ToFloat<<<num_blocks, block_size>>>((int8_t *)src, (float *)dst,
                                                  size);
  } else if (src_type == CUDNN_DATA_FLOAT && dst_type == CUDNN_DATA_UINT8) {
    kernelFloatToUint8<<<num_blocks, block_size>>>((float *)src, (uint8_t *)dst,
                                                   size, rmode);
  } else if (src_type == CUDNN_DATA_UINT8 && dst_type == CUDNN_DATA_FLOAT) {
    kernelUint8ToFloat<<<num_blocks, block_size>>>((uint8_t *)src, (float *)dst,
                                                   size);
  } else {
    // not implemented
    return cudaErrorNotSupported;
  }
  return cudaSuccess;
}

template <typename T> __global__ void kernelPrint(T *data, int size) {
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  if (idx < size) {
    printf("Data[%d] = %g\n", idx, (float)data[idx]);
  }
}

void cudaPrint(void *data, int size, cudnnDataType_t type) {
  switch (type) {
  case CUDNN_DATA_FLOAT:
    kernelPrint<<<(size + 256) / 256, 256>>>((float *)data, size);
    break;
  case CUDNN_DATA_INT32:
    kernelPrint<<<(size + 256) / 256, 256>>>((int32_t *)data, size);
    break;
  case CUDNN_DATA_INT8:
    kernelPrint<<<(size + 256) / 256, 256>>>((int8_t *)data, size);
    break;
  case CUDNN_DATA_UINT8:
    kernelPrint<<<(size + 256) / 256, 256>>>((uint8_t *)data, size);
    break;
  }
}

template <typename T> __global__ void kernelRelu(T *data, int size) {
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  if (idx < size) {
    data[idx] = max(static_cast<T>(0), data[idx]);
  }
}

void cudaRelu(void *data, int size, cudnnDataType_t type) {
  int num_blocks = CUDA_NUM_BLOCKS(size);
  int block_size = CUDA_BLOCK_SIZE;
  switch (type) {
  case CUDNN_DATA_FLOAT:
    kernelRelu<<<num_blocks, block_size>>>((float *)data, size);
    break;
  case CUDNN_DATA_INT32:
    kernelRelu<<<num_blocks, block_size>>>((int32_t *)data, size);
    break;
  case CUDNN_DATA_INT8:
    kernelRelu<<<num_blocks, block_size>>>((int8_t *)data, size);
    break;
  }
}