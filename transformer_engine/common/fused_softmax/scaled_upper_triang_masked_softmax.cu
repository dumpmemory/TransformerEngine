/*************************************************************************
 * Copyright (c) 2022-2025, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 *
 * See LICENSE for license information.
 ************************************************************************/

#include <assert.h>
#include <cuda.h>
#include <cuda_fp16.h>
#include <cuda_profiler_api.h>
#include <cuda_runtime.h>
#include <stdint.h>
#include <transformer_engine/softmax.h>

#include <cfloat>
#include <limits>

#include "../common.h"
#include "../util/logging.h"
#include "../utils.cuh"

namespace transformer_engine {

template <typename Datatype, int ELEMENTS_PER_LDG>
__device__ __inline__ void copy_vector(Datatype *dst, const Datatype *src);

template <>
__device__ __inline__ void copy_vector<bf16, 1>(bf16 *dst, const bf16 *src) {
  *dst = *src;
}

template <>
__device__ __inline__ void copy_vector<bf16, 4>(bf16 *dst, const bf16 *src) {
  *((float2 *)dst) = *((float2 *)src);  // NOLINT(*)
}

template <>
__device__ __inline__ void copy_vector<fp16, 1>(fp16 *dst, const fp16 *src) {
  *dst = *src;
}

template <>
__device__ __inline__ void copy_vector<fp16, 4>(fp16 *dst, const fp16 *src) {
  *((float2 *)dst) = *((float2 *)src);  // NOLINT(*)
}

template <>
__device__ __inline__ void copy_vector<uint8_t, 1>(uint8_t *dst, const uint8_t *src) {
  *dst = *src;
}

template <>
__device__ __inline__ void copy_vector<uint8_t, 4>(uint8_t *dst, const uint8_t *src) {
  *((half2 *)dst) = *((half2 *)src);  // NOLINT(*)
}

template <typename Datatype, int ELEMENTS_PER_LDG>
__device__ __inline__ void copy_zero_vector(Datatype *dst);

template <>
__device__ __inline__ void copy_zero_vector<bf16, 1>(bf16 *dst) {
  *dst = 0.0f;
}

template <>
__device__ __inline__ void copy_zero_vector<bf16, 4>(bf16 *dst) {
  *((float2 *)dst) = make_float2(0.0f, 0.0f);  // NOLINT(*)
}

template <>
__device__ __inline__ void copy_zero_vector<fp16, 1>(fp16 *dst) {
  *dst = 0.0f;
}

template <>
__device__ __inline__ void copy_zero_vector<fp16, 4>(fp16 *dst) {
  *((float2 *)dst) = make_float2(0.0f, 0.0f);  // NOLINT(*)
}

template <typename T>
struct Add {
  __device__ __forceinline__ T operator()(T a, T b) const { return a + b; }
};

template <typename T>
struct Max {
  __device__ __forceinline__ T operator()(T a, T b) const { return a < b ? b : a; }
};

template <typename T>
__device__ __forceinline__ T WARP_SHFL_XOR_NATIVE(T value, int laneMask, int width = warpSize,
                                                  unsigned int mask = 0xffffffff) {
#if CUDA_VERSION >= 9000
  return __shfl_xor_sync(mask, value, laneMask, width);
#else
  return __shfl_xor(value, laneMask, width);
#endif
}

template <typename acc_t, int WARP_BATCH, int WARP_SIZE, template <typename> class ReduceOp>
__device__ __forceinline__ void warp_reduce(acc_t *sum) {
  ReduceOp<acc_t> r;
#pragma unroll
  for (int offset = WARP_SIZE / 2; offset > 0; offset /= 2) {
#pragma unroll
    for (int i = 0; i < WARP_BATCH; ++i) {
      acc_t b = WARP_SHFL_XOR_NATIVE(sum[i], offset, WARP_SIZE);
      sum[i] = r(sum[i], b);
    }
  }
}

/*
 * Extended softmax (from native aten pytorch) with following additional features
 * 1) input scaling
 * 2) Implicit time (diagonal masking)
 */
template <typename input_t, typename output_t, typename acc_t, int log2_elements>
__global__ void scaled_upper_triang_masked_softmax_warp_forward(output_t *dst, const input_t *src,
                                                                const acc_t scale,
                                                                int micro_batch_size, int stride,
                                                                int element_count) {
  // WARP_SIZE and WARP_BATCH must match the return values batches_per_warp and
  // warp_size of method warp_softmax_forward_kernel.
  constexpr int next_power_of_two = 1 << log2_elements;
  constexpr int WARP_SIZE =
      (next_power_of_two < THREADS_PER_WARP) ? next_power_of_two : THREADS_PER_WARP;
  constexpr int WARP_ITERATIONS = next_power_of_two / WARP_SIZE;
  constexpr int WARP_BATCH = (next_power_of_two <= 128) ? 2 : 1;
  constexpr int ELEMENTS_PER_LDG_STG = (WARP_ITERATIONS < 4) ? 1 : 4;

  size_t first_batch =
      (blockDim.y * blockIdx.y + threadIdx.y) * gridDim.x * WARP_BATCH + blockIdx.x;
  int local_seq = blockIdx.x + 1;
  int warp_iteration_limit = (local_seq + ELEMENTS_PER_LDG_STG * WARP_SIZE - 1) / WARP_SIZE;

  // micro_batch_size might not be a multiple of WARP_BATCH. Check how
  // many batches have to computed within this WARP.
  int local_batches = micro_batch_size - first_batch;
  if (local_batches > WARP_BATCH) local_batches = WARP_BATCH;

  // there might be multiple batches per warp. compute the index within the batch
  int local_idx = threadIdx.x;

  size_t thread_offset = first_batch * stride + ELEMENTS_PER_LDG_STG * local_idx;
  src += thread_offset;
  dst += thread_offset;

  // load data from global memory
  acc_t elements[WARP_BATCH][WARP_ITERATIONS];
  input_t temp_data[ELEMENTS_PER_LDG_STG];
#pragma unroll
  for (int i = 0; i < WARP_BATCH; ++i) {
    int batch_element_count = (i >= local_batches) ? 0 : local_seq;

#pragma unroll
    for (int it = 0; it < WARP_ITERATIONS; it += ELEMENTS_PER_LDG_STG) {
      int element_index = ELEMENTS_PER_LDG_STG * local_idx + it * WARP_SIZE;

      if (element_index < batch_element_count) {
        copy_vector<input_t, ELEMENTS_PER_LDG_STG>(
            temp_data, src + i * element_count * stride + it * WARP_SIZE);

#pragma unroll
        for (int element = 0; element < ELEMENTS_PER_LDG_STG; ++element) {
          if ((element_index + element) < batch_element_count) {
            elements[i][it + element] = (acc_t)temp_data[element] * scale;
          } else {
            elements[i][it + element] = -std::numeric_limits<acc_t>::infinity();
          }
        }
      } else {
#pragma unroll
        for (int element = 0; element < ELEMENTS_PER_LDG_STG; ++element) {
          elements[i][it + element] = -std::numeric_limits<acc_t>::infinity();
        }
      }
    }
  }

  // compute max_value
  acc_t max_value[WARP_BATCH];
#pragma unroll
  for (int i = 0; i < WARP_BATCH; ++i) {
    max_value[i] = elements[i][0];
#pragma unroll
    for (int it = 1; it < WARP_ITERATIONS; ++it) {
      max_value[i] = (max_value[i] > elements[i][it]) ? max_value[i] : elements[i][it];
    }
  }
  warp_reduce<acc_t, WARP_BATCH, WARP_SIZE, Max>(max_value);

  acc_t sum[WARP_BATCH]{0.0f};
#pragma unroll
  for (int i = 0; i < WARP_BATCH; ++i) {
#pragma unroll
    for (int it = 0; it < WARP_ITERATIONS; ++it) {
      if (it < warp_iteration_limit) {
        elements[i][it] = std::exp((elements[i][it] - max_value[i]));
        sum[i] += elements[i][it];
      }
    }
  }
  warp_reduce<acc_t, WARP_BATCH, WARP_SIZE, Add>(sum);

  // store result
  output_t out[ELEMENTS_PER_LDG_STG];
#pragma unroll
  for (int i = 0; i < WARP_BATCH; ++i) {
    if (i >= local_batches) break;
#pragma unroll
    for (int it = 0; it < WARP_ITERATIONS; it += ELEMENTS_PER_LDG_STG) {
      int element_index = ELEMENTS_PER_LDG_STG * local_idx + it * WARP_SIZE;

      if (element_index < local_seq) {
#pragma unroll
        for (int element = 0; element < ELEMENTS_PER_LDG_STG; ++element) {
          if (element_index + element < local_seq) {
            out[element] = elements[i][it + element] / sum[i];
          } else {
            out[element] = 0.0f;
          }
        }
        copy_vector<output_t, ELEMENTS_PER_LDG_STG>(
            dst + i * element_count * stride + it * WARP_SIZE, out);
      } else if (element_index < element_count) {
        copy_zero_vector<output_t, ELEMENTS_PER_LDG_STG>(dst + i * element_count * stride +
                                                         it * WARP_SIZE);
      } else {
        break;
      }
    }
  }
}

template <typename input_t, typename output_t, typename acc_t, int log2_elements>
__global__ void scaled_upper_triang_masked_softmax_warp_backward(output_t *gradInput,
                                                                 const input_t *grad,
                                                                 const input_t *output, acc_t scale,
                                                                 int micro_batch_size, int stride,
                                                                 int element_count) {
  // WARP_SIZE and WARP_BATCH must match the return values batches_per_warp and
  // warp_size of method warp_softmax_backward_kernel.
  constexpr int next_power_of_two = 1 << log2_elements;
  constexpr int WARP_SIZE =
      (next_power_of_two < THREADS_PER_WARP) ? next_power_of_two : THREADS_PER_WARP;
  constexpr int WARP_ITERATIONS = next_power_of_two / WARP_SIZE;
  constexpr int WARP_BATCH = (next_power_of_two <= 128) ? 2 : 1;
  constexpr int ELEMENTS_PER_LDG_STG = (WARP_ITERATIONS < 4) ? 1 : 4;

  size_t first_batch =
      (blockDim.y * blockIdx.y + threadIdx.y) * gridDim.x * WARP_BATCH + blockIdx.x;
  int local_seq = blockIdx.x + 1;

  // micro_batch_size might not be a multiple of WARP_BATCH. Check how
  // many batches have to computed within this WARP.
  int local_batches = micro_batch_size - first_batch;
  if (local_batches > WARP_BATCH) local_batches = WARP_BATCH;

  // there might be multiple batches per warp. compute the index within the batch
  int local_idx = threadIdx.x;

  // the first element to process by the current thread
  size_t thread_offset = first_batch * stride + ELEMENTS_PER_LDG_STG * local_idx;
  grad += thread_offset;
  output += thread_offset;
  gradInput += thread_offset;

  // load data from global memory
  acc_t grad_reg[WARP_BATCH][WARP_ITERATIONS]{0.0f};
  acc_t output_reg[WARP_BATCH][WARP_ITERATIONS]{0.0f};
  input_t temp_grad[ELEMENTS_PER_LDG_STG];
  input_t temp_output[ELEMENTS_PER_LDG_STG];
#pragma unroll
  for (int i = 0; i < WARP_BATCH; ++i) {
    int batch_element_count = (i >= local_batches) ? 0 : local_seq;

#pragma unroll
    for (int it = 0; it < WARP_ITERATIONS; it += ELEMENTS_PER_LDG_STG) {
      int element_index = ELEMENTS_PER_LDG_STG * local_idx + it * WARP_SIZE;
      if (element_index < batch_element_count) {
        copy_vector<input_t, ELEMENTS_PER_LDG_STG>(
            temp_grad, grad + i * element_count * stride + it * WARP_SIZE);
        copy_vector<input_t, ELEMENTS_PER_LDG_STG>(
            temp_output, output + i * element_count * stride + it * WARP_SIZE);

#pragma unroll
        for (int element = 0; element < ELEMENTS_PER_LDG_STG; ++element) {
          if (element_index + element < batch_element_count) {
            output_reg[i][it + element] = (acc_t)temp_output[element];
          }
        }
#pragma unroll
        for (int element = 0; element < ELEMENTS_PER_LDG_STG; ++element) {
          if (element_index + element < batch_element_count) {
            grad_reg[i][it + element] = (acc_t)temp_grad[element] * output_reg[i][it + element];
          }
        }
      }
    }
  }

  acc_t sum[WARP_BATCH];
#pragma unroll
  for (int i = 0; i < WARP_BATCH; ++i) {
    sum[i] = grad_reg[i][0];
#pragma unroll
    for (int it = 1; it < WARP_ITERATIONS; ++it) {
      sum[i] += grad_reg[i][it];
    }
  }
  warp_reduce<acc_t, WARP_BATCH, WARP_SIZE, Add>(sum);

  // store result
#pragma unroll
  for (int i = 0; i < WARP_BATCH; ++i) {
    if (i >= local_batches) break;
#pragma unroll
    for (int it = 0; it < WARP_ITERATIONS; it += ELEMENTS_PER_LDG_STG) {
      int element_index = ELEMENTS_PER_LDG_STG * local_idx + it * WARP_SIZE;
      if (element_index < element_count) {
        // compute gradients
        output_t out[ELEMENTS_PER_LDG_STG];
#pragma unroll
        for (int element = 0; element < ELEMENTS_PER_LDG_STG; ++element) {
          out[element] = (output_t)(scale * (grad_reg[i][it + element] -
                                             output_reg[i][it + element] * sum[i]));
        }
        copy_vector<output_t, ELEMENTS_PER_LDG_STG>(
            gradInput + i * element_count * stride + it * WARP_SIZE, out);
      }
    }
  }
}

template <typename input_t, typename output_t, typename acc_t>
void dispatch_scaled_upper_triang_masked_softmax_forward(output_t *dst, const input_t *src,
                                                         const input_t scale, int softmax_elements,
                                                         int softmax_elements_stride,
                                                         int attn_batches, cudaStream_t stream) {
  NVTE_CHECK(softmax_elements >= 0 && softmax_elements <= 16384, "Unsupported shape.");
  if (softmax_elements == 0) {
    return;
  } else {
    int log2_elements = log2_ceil(softmax_elements);
    const int next_power_of_two = 1 << log2_elements;
    int seq_len = softmax_elements;
    int batch_count = attn_batches * seq_len;

    // This value must match the WARP_SIZE constexpr
    // value computed inside softmax_warp_forward.
    int warp_size = (next_power_of_two < THREADS_PER_WARP) ? next_power_of_two : THREADS_PER_WARP;

    // This value must match the WARP_BATCH constexpr
    // value computed inside softmax_warp_forward.
    int batches_per_warp = (next_power_of_two <= 128) ? 2 : 1;

    // use 128 threads per block to maximimize gpu utilization
    constexpr int threads_per_block = 128;

    int warps_per_block = (threads_per_block / warp_size);
    int batches_per_block = warps_per_block * batches_per_warp;
    NVTE_CHECK(attn_batches % batches_per_block == 0, "Unsupported shape.");

    int blocks_per_seq = attn_batches / batches_per_block;
    dim3 blocks(seq_len, blocks_per_seq, 1);
    dim3 threads(warp_size, warps_per_block, 1);
    // Launch code would be more elegant if C++ supported FOR CONSTEXPR
    switch (log2_elements) {
      case 0:  // 1
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 0>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 1:  // 2
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 1>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 2:  // 4
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 2>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 3:  // 8
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 3>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 4:  // 16
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 4>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 5:  // 32
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 5>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 6:  // 64
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 6>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 7:  // 128
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 7>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 8:  // 256
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 8>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 9:  // 512
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 9>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 10:  // 1024
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 10>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 11:  // 2048
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 11>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 12:  // 4096
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 12>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 13:  // 8192
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 13>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      case 14:  // 16384
        scaled_upper_triang_masked_softmax_warp_forward<input_t, output_t, acc_t, 14>
            <<<blocks, threads, 0, stream>>>(dst, src, scale, batch_count, softmax_elements_stride,
                                             softmax_elements);
        break;
      default:
        break;
    }
  }
}

template <typename input_t, typename output_t, typename acc_t>
void dispatch_scaled_upper_triang_masked_softmax_backward(output_t *grad_input, const input_t *grad,
                                                          const input_t *output, const acc_t scale,
                                                          int softmax_elements,
                                                          int softmax_elements_stride,
                                                          int attn_batches, cudaStream_t stream) {
  NVTE_CHECK(softmax_elements >= 0 && softmax_elements <= 16384, "Unsupported shape.");
  if (softmax_elements == 0) {
    return;
  } else {
    int log2_elements = log2_ceil(softmax_elements);
    const int next_power_of_two = 1 << log2_elements;
    int seq_len = softmax_elements;
    int batch_count = attn_batches * seq_len;

    // This value must match the WARP_SIZE constexpr
    // value computed inside softmax_warp_backward.
    int warp_size = (next_power_of_two < THREADS_PER_WARP) ? next_power_of_two : THREADS_PER_WARP;

    // This value must match the WARP_BATCH constexpr
    // value computed inside softmax_warp_backward.
    int batches_per_warp = (next_power_of_two <= 128) ? 2 : 1;

    // use 128 threads per block to maximimize gpu utilization
    constexpr int threads_per_block = 128;

    int warps_per_block = (threads_per_block / warp_size);
    int batches_per_block = warps_per_block * batches_per_warp;
    NVTE_CHECK(attn_batches % batches_per_block == 0, "Unsupported shape.");

    int blocks_per_seq = attn_batches / batches_per_block;
    dim3 blocks(seq_len, blocks_per_seq, 1);
    dim3 threads(warp_size, warps_per_block, 1);
    // Launch code would be more elegant if C++ supported FOR CONSTEXPR
    switch (log2_elements) {
      case 0:  // 1
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 0>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 1:  // 2
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 1>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 2:  // 4
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 2>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 3:  // 8
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 3>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 4:  // 16
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 4>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 5:  // 32
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 5>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 6:  // 64
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 6>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 7:  // 128
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 7>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 8:  // 256
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 8>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 9:  // 512
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 9>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 10:  // 1024
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 10>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 11:  // 2048
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 11>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 12:  // 4096
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 12>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 13:  // 8192
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 13>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      case 14:  // 16384
        scaled_upper_triang_masked_softmax_warp_backward<input_t, output_t, acc_t, 14>
            <<<blocks, threads, 0, stream>>>(grad_input, grad, output, scale, batch_count,
                                             softmax_elements_stride, softmax_elements);
        break;
      default:
        break;
    }
  }
}

void scaled_upper_triang_masked_softmax_forward(const Tensor input, Tensor *softmax_results,
                                                float scale_factor, cudaStream_t stream) {
  const int attn_batches = input.data.shape[0];
  const int seq_len = input.data.shape[1];

  TRANSFORMER_ENGINE_TYPE_SWITCH_16BIT(
      input.data.dtype, softmax_type,
      dispatch_scaled_upper_triang_masked_softmax_forward<softmax_type, softmax_type, float>(
          reinterpret_cast<softmax_type *>(softmax_results->data.dptr),
          reinterpret_cast<const softmax_type *>(input.data.dptr), scale_factor, seq_len, seq_len,
          attn_batches, stream););
}

void scaled_upper_triang_masked_softmax_backward(Tensor output_grads, const Tensor incoming_grads,
                                                 const Tensor softmax_results, float scale_factor,
                                                 cudaStream_t stream) {
  const int attn_batches = output_grads.data.shape[0];
  const int seq_len = output_grads.data.shape[1];

  // Softmax Grad
  TRANSFORMER_ENGINE_TYPE_SWITCH_16BIT(
      output_grads.data.dtype, softmax_type,
      dispatch_scaled_upper_triang_masked_softmax_backward<softmax_type, softmax_type, float>(
          reinterpret_cast<softmax_type *>(output_grads.data.dptr),
          reinterpret_cast<softmax_type const *>(incoming_grads.data.dptr),
          reinterpret_cast<softmax_type const *>(softmax_results.data.dptr), scale_factor, seq_len,
          seq_len, attn_batches, stream););
}

}  // end namespace transformer_engine

void nvte_scaled_upper_triang_masked_softmax_forward(const NVTETensor input,
                                                     NVTETensor softmax_results, float scale_factor,
                                                     cudaStream_t stream) {
  using namespace transformer_engine;
  scaled_upper_triang_masked_softmax_forward(*convertNVTETensorCheck(input),
                                             convertNVTETensorCheck(softmax_results), scale_factor,
                                             stream);
}

void nvte_scaled_upper_triang_masked_softmax_backward(const NVTETensor incoming_grads,
                                                      const NVTETensor softmax_results,
                                                      NVTETensor output_grads, float scale_factor,
                                                      cudaStream_t stream) {
  using namespace transformer_engine;
  scaled_upper_triang_masked_softmax_backward(
      *convertNVTETensorCheck(output_grads), *convertNVTETensorCheck(incoming_grads),
      *convertNVTETensorCheck(softmax_results), scale_factor, stream);
}
