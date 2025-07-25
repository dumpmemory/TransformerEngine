/*************************************************************************
 * Copyright (c) 2022-2025, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 *
 * See LICENSE for license information.
 ************************************************************************/

#include <cublasLt.h>
#include <cublas_v2.h>
#include <cuda.h>
#include <transformer_engine/gemm.h>
#include <transformer_engine/multi_stream.h>
#include <transformer_engine/transformer_engine.h>

#include <cstdint>
#include <mutex>

#include "../common.h"
#include "../util/handle_manager.h"
#include "../util/logging.h"
#include "../util/multi_stream.h"
#include "common/util/cuda_runtime.h"

namespace {

cudaDataType_t get_cuda_dtype(const transformer_engine::DType t) {
  using namespace transformer_engine;
  switch (t) {
    case DType::kFloat16:
      return CUDA_R_16F;
    case DType::kFloat32:
      return CUDA_R_32F;
    case DType::kBFloat16:
      return CUDA_R_16BF;
    case DType::kFloat8E4M3:
      return CUDA_R_8F_E4M3;
    case DType::kFloat8E5M2:
      return CUDA_R_8F_E5M2;
    default:
      NVTE_ERROR("Invalid type");
  }
}

uint32_t _getAlignment(uintptr_t address) {
  // alignment are in bytes
  uint32_t alignment = 256;
  for (;; alignment /= 2) {
    if (address % alignment == 0) {
      return alignment;
    }
  }
}

inline void CreateCublasHandle(cublasLtHandle_t *handle) {
  NVTE_CHECK_CUBLAS(cublasLtCreate(handle));
}

/* Parameters for cuBLAS GEMM
 *
 * cuBLAS follows the BLAS convention of column-major ordering. This
 * is different than the row-major that is typically used in
 * Transformer Engine.
 *
 */
struct GemmParam {
  void *A = nullptr;
  void *B = nullptr;
  cublasOperation_t transA = CUBLAS_OP_N;
  cublasOperation_t transB = CUBLAS_OP_N;
  transformer_engine::DType Atype = transformer_engine::DType::kNumTypes;
  transformer_engine::DType Btype = transformer_engine::DType::kNumTypes;
  void *A_scale_inv = nullptr;
  void *B_scale_inv = nullptr;
  int lda = 0;  // A column strides
  int ldb = 0;  // B column strides
};

/* Populate parameters for cuBLAS GEMM
 *
 * cuBLAS follows the BLAS convention of column-major ordering. This
 * is different than the row-major that is typically used in
 * Transformer Engine.
 *
 */
GemmParam CanonicalizeGemmInput(const transformer_engine::Tensor &A, const cublasOperation_t transA,
                                const transformer_engine::Tensor &B, const cublasOperation_t transB,
                                int m, int n, int k) {
  using namespace transformer_engine;
  NVTE_CHECK(
      A.scaling_mode == B.scaling_mode ||
          (A.scaling_mode == NVTE_BLOCK_SCALING_1D && B.scaling_mode == NVTE_BLOCK_SCALING_2D) ||
          (A.scaling_mode == NVTE_BLOCK_SCALING_2D && B.scaling_mode == NVTE_BLOCK_SCALING_1D),
      "Inputs A and B to GEMM need to have compatible scaling modes, but got A.scaling_mode = " +
          to_string(A.scaling_mode) + ", B.scaling_mode = " + to_string(B.scaling_mode));
  NVTE_CHECK(A.has_data() || A.has_columnwise_data(), "Input A does not hold any data!");
  NVTE_CHECK(B.has_data() || B.has_columnwise_data(), "Input B does not hold any data!");
  GemmParam ret;

  // Transpose mode with column-major ordering
  bool is_A_transposed = transA == CUBLAS_OP_T;
  bool is_B_transposed = transB == CUBLAS_OP_T;

  // Configure A matrix
  if (is_tensor_scaling(A.scaling_mode)) {
    // Unscaled or FP8 tensor scaling
    ret.A = A.data.dptr;
    ret.transA = transA;
    ret.Atype = A.data.dtype;
    ret.A_scale_inv = A.scale_inv.dptr;
    ret.lda = is_A_transposed ? k : m;
    if (!nvte_is_non_tn_fp8_gemm_supported() && !is_A_transposed) {
      // Hopper only supports TN GEMMs for FP8. "Column-wise data" is transpose of data.
      if (A.has_columnwise_data() && is_fp8_dtype(A.columnwise_data.dtype)) {
        ret.A = A.columnwise_data.dptr;
        ret.transA = CUBLAS_OP_T;
        ret.Atype = A.columnwise_data.dtype;
        ret.A_scale_inv = A.columnwise_scale_inv.dptr;
        ret.lda = k;
      } else {
        NVTE_CHECK(!is_fp8_dtype(ret.Atype), "Input A is missing column-wise usage");
      }
    }
  } else if (is_mxfp_scaling(A.scaling_mode)) {
    // MXFP8
    // Note: Row-wise and column-wise data are scaled along different
    // dimensions (with matrix interpreted in row-major order).
    if (is_A_transposed) {
      NVTE_CHECK(A.has_data(), "Input A is missing row-wise usage");
    } else {
      NVTE_CHECK(A.has_columnwise_data(), "Input A is missing column-wise usage");
    }
    ret.A = is_A_transposed ? A.data.dptr : A.columnwise_data.dptr;
    ret.transA = transA;
    ret.Atype = is_A_transposed ? A.data.dtype : A.columnwise_data.dtype;
    ret.A_scale_inv = is_A_transposed ? A.scale_inv.dptr : A.columnwise_scale_inv.dptr;
    ret.lda = is_A_transposed ? k : m;
  } else if (A.scaling_mode == NVTE_BLOCK_SCALING_1D || A.scaling_mode == NVTE_BLOCK_SCALING_2D) {
    // FP8 block scaling
    // Note: Hopper only supports TN GEMMs for FP8. "Column-wise data" is transpose of data.
    if (is_A_transposed) {
      NVTE_CHECK(A.has_data(), "Input A is missing row-wise usage");
    } else {
      NVTE_CHECK(A.has_columnwise_data(), "Input A is missing column-wise usage");
    }
    ret.A = is_A_transposed ? A.data.dptr : A.columnwise_data.dptr;
    ret.transA = CUBLAS_OP_T;
    ret.Atype = is_A_transposed ? A.data.dtype : A.columnwise_data.dtype;
    ret.A_scale_inv = is_A_transposed ? A.scale_inv.dptr : A.columnwise_scale_inv.dptr;
    ret.lda = k;

    // Requirements from https://docs.nvidia.com/cuda/cublas/#tensor-core-usage
    NVTE_CHECK((ret.lda % 16) == 0,
               "Inner dimension requirement on NVTE_BLOCK_SCALING GEMM. Caller must pad.");
    // Divisibility of 8 derived from FP8 (m * CTypeSize) % 16 == 0 requirement.
    // Smallest supported CType is 2 bytes in this scaling mode.
    NVTE_CHECK((m % 8) == 0,
               "Outer dimension requirement on A for NVTE_BLOCK_SCALING GEMM. Caller must pad.");
  } else {
    NVTE_ERROR("A has unsupported scaling mode");
  }

  // Configure B matrix
  if (is_tensor_scaling(B.scaling_mode)) {
    // Unscaled or FP8 tensor scaling
    ret.B = B.data.dptr;
    ret.transB = transB;
    ret.Btype = B.data.dtype;
    ret.B_scale_inv = B.scale_inv.dptr;
    ret.ldb = is_B_transposed ? n : k;
    if (!nvte_is_non_tn_fp8_gemm_supported() && is_B_transposed) {
      // Hopper only supports TN GEMMs for FP8. "Column-wise data" is transpose of data.
      if (B.has_columnwise_data() && is_fp8_dtype(B.columnwise_data.dtype)) {
        ret.B = B.columnwise_data.dptr;
        ret.transB = CUBLAS_OP_N;
        ret.Btype = B.columnwise_data.dtype;
        ret.B_scale_inv = B.columnwise_scale_inv.dptr;
        ret.ldb = k;
      } else {
        NVTE_CHECK(!is_fp8_dtype(ret.Btype), "Input B is missing column-wise usage");
      }
    }
  } else if (is_mxfp_scaling(B.scaling_mode)) {
    // MXFP8
    // Note: Row-wise and column-wise data are scaled along different
    // dimensions (with matrix interpreted in row-major order).
    if (is_B_transposed) {
      NVTE_CHECK(B.has_columnwise_data(), "Input B is missing column-wise usage");
    } else {
      NVTE_CHECK(B.has_data(), "Input B is missing row-wise usage");
    }
    ret.B = is_B_transposed ? B.columnwise_data.dptr : B.data.dptr;
    ret.transB = transB;
    ret.Btype = is_B_transposed ? B.columnwise_data.dtype : B.data.dtype;
    ret.B_scale_inv = is_B_transposed ? B.columnwise_scale_inv.dptr : B.scale_inv.dptr;
    ret.ldb = is_B_transposed ? n : k;
  } else if (B.scaling_mode == NVTE_BLOCK_SCALING_1D || B.scaling_mode == NVTE_BLOCK_SCALING_2D) {
    // FP8 block scaling
    // Note: Hopper only supports TN GEMMs for FP8. "Column-wise data" is transpose of data.
    if (is_B_transposed) {
      NVTE_CHECK(B.has_columnwise_data(), "Input B is missing column-wise usage");
    } else {
      NVTE_CHECK(B.has_data(), "Input B is missing row-wise usage");
    }
    ret.B = is_B_transposed ? B.columnwise_data.dptr : B.data.dptr;
    ret.transB = CUBLAS_OP_N;
    ret.Btype = is_B_transposed ? B.columnwise_data.dtype : B.data.dtype;
    ret.B_scale_inv = is_B_transposed ? B.columnwise_scale_inv.dptr : B.scale_inv.dptr;
    ret.ldb = k;

    // Requirements from
    // https://docs.nvidia.com/cuda/cublas/#tensor-core-usage
    NVTE_CHECK((ret.ldb % 16) == 0,
               "B tensor stride requirement on NVTE_BLOCK_SCALING GEMM. Caller must pad.");
    if (B.scaling_mode == NVTE_BLOCK_SCALING_1D) {
      // Observed this requirement only present for B tensor is 1D quantized.
      NVTE_CHECK((n % 8) == 0,
                 "Outer dimension requirement on B for NVTE_BLOCK_SCALING GEMM. Caller must pad.");
    }
  } else {
    NVTE_ERROR("B has unsupported scaling mode");
  }

  return ret;
}

/* cuBLAS version number at run-time */
size_t cublas_version() {
  // Cache version to avoid cuBLAS logging overhead
  static size_t version = cublasLtGetVersion();
  return version;
}

}  // namespace

namespace transformer_engine {

using cublasHandleManager = detail::HandleManager<cublasLtHandle_t, CreateCublasHandle>;

void cublas_gemm(const Tensor *inputA, const Tensor *inputB, Tensor *outputD,
                 const Tensor *inputBias, Tensor *outputPreGelu, cublasOperation_t transa,
                 cublasOperation_t transb, bool grad, void *workspace, size_t workspaceSize,
                 bool accumulate, bool use_split_accumulator, int math_sm_count, int m_split,
                 int n_split, bool gemm_producer, const Tensor *inputCounter, cudaStream_t stream) {
  // Tensor dims in row-major order
  const int A0 = inputA->flat_first_dim();
  const int A1 = inputA->flat_last_dim();
  const int B0 = inputB->flat_first_dim();
  const int B1 = inputB->flat_last_dim();

  // GEMM dims in column-major order
  const int m = transa == CUBLAS_OP_T ? A0 : A1;
  const int n = transb == CUBLAS_OP_T ? B1 : B0;
  const int k = transa == CUBLAS_OP_T ? A1 : A0;
  NVTE_CHECK((transb == CUBLAS_OP_T ? B0 : B1) == k,
             "GEMM inputs have incompatible dimensions (A is ", A0, "x", A1, ", B is ", B0, "x", B1,
             ")");
  const int ldd = m;

  // Return immediately if GEMM is trivial
  if (m <= 0 || n <= 0) {
    return;
  }
  NVTE_CHECK(k > 0);

  const GemmParam param = CanonicalizeGemmInput(*inputA, transa, *inputB, transb, m, n, k);

  void *C = outputD->data.dptr;
  void *D = outputD->data.dptr;
  void *D_scale = outputD->scale.dptr;
  void *D_amax = outputD->amax.dptr;
  void *bias_ptr = inputBias->data.dptr;
  const bool bias = bias_ptr != nullptr;
  void *pre_gelu_out = outputPreGelu->data.dptr;
  void *counter = nullptr;
  if (inputCounter != nullptr) {
    counter = inputCounter->data.dptr;
  }
  const bool gelu = pre_gelu_out != nullptr;
  const bool use_fp8 = is_fp8_dtype(param.Atype) || is_fp8_dtype(param.Btype);

  const cudaDataType_t A_type = get_cuda_dtype(param.Atype);
  const cudaDataType_t B_type = get_cuda_dtype(param.Btype);
  const cudaDataType_t D_type = get_cuda_dtype(outputD->data.dtype);
  const cudaDataType_t bias_type = get_cuda_dtype(inputBias->data.dtype);

  NVTE_CHECK(!is_fp8_dtype(param.Atype) || param.A_scale_inv != nullptr,
             "FP8 input to GEMM requires inverse of scale!");
  NVTE_CHECK(!is_fp8_dtype(param.Btype) || param.B_scale_inv != nullptr,
             "FP8 input to GEMM requires inverse of scale!");

  // check consistency of arguments:
  // if fp8 is desired, context cannot be null
  // fp8 + gelu fusion + fp8 aux is unavailable right now.
  if (use_fp8 && gelu) {
    NVTE_CHECK(!is_fp8_dtype(outputPreGelu->data.dtype),
               "fp8 Aux output for gemm + gelu fusion not supported!");
  }
  if (is_fp8_dtype(outputD->data.dtype)) {
    NVTE_CHECK(!accumulate, "Accumulation mode not supported with FP8 GEMM output!");
  }

  float one = 1.0;
  float zero = 0.0;
  float beta = (accumulate) ? one : zero;

  cublasLtHandle_t handle = cublasHandleManager::Instance().GetHandle();

  cublasLtMatmulDesc_t operationDesc = nullptr;
  cublasLtMatrixLayout_t Adesc = nullptr, Bdesc = nullptr, Cdesc = nullptr, Ddesc = nullptr;
  cublasLtMatmulPreference_t preference = nullptr;
  int returnedResults = 0;
  cublasLtMatmulHeuristicResult_t heuristicResult = {};
  cublasLtEpilogue_t epilogue = CUBLASLT_EPILOGUE_DEFAULT;

  int64_t ld_gelumat = (int64_t)ldd;

  // Use TF32 only for pure FP32 GEMM.
  cublasComputeType_t gemm_compute_type = CUBLAS_COMPUTE_32F;
  if (A_type == CUDA_R_32F && B_type == CUDA_R_32F && D_type == CUDA_R_32F) {
    gemm_compute_type = CUBLAS_COMPUTE_32F_FAST_TF32;
  }

  // Create matrix descriptors. Not setting any extra attributes.
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Adesc, A_type, param.transA == CUBLAS_OP_N ? m : k,
                                               param.transA == CUBLAS_OP_N ? k : m, param.lda));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Bdesc, B_type, param.transB == CUBLAS_OP_N ? k : n,
                                               param.transB == CUBLAS_OP_N ? n : k, param.ldb));

  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Ddesc, D_type, m, n, ldd));

  NVTE_CHECK_CUBLAS(cublasLtMatmulDescCreate(&operationDesc, gemm_compute_type, CUDA_R_32F));
  NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSA,
                                                   &param.transA, sizeof(param.transA)));
  NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_TRANSB,
                                                   &param.transB, sizeof(param.transB)));
  // Set math SM count
  if (math_sm_count != 0) {
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_SM_COUNT_TARGET,
                                                     &math_sm_count, sizeof(math_sm_count)));
  }

  // set fp8 attributes -- input and output types should already be set to fp8 as appropriate
  // Note: gelu fusion isn't available right now, and we don't need
  // amax(D) either (next op is high precision).
  if (use_fp8) {
    // Split accumulator.
    const int8_t fastAccuMode = (use_split_accumulator) ? 0 : 1;
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_FAST_ACCUM,
                                                     &fastAccuMode, sizeof(fastAccuMode)));

    // Scaling factors.
#if CUBLAS_VERSION >= 120800
    cublasLtMatmulMatrixScale_t scaling_mode_a;
    cublasLtMatmulMatrixScale_t scaling_mode_b;
#endif  // CUBLAS_VERSION >= 120800
    if ((is_tensor_scaling(inputA->scaling_mode) && is_tensor_scaling(inputB->scaling_mode))) {
      void *A_scale_inverse = param.A_scale_inv;
      void *B_scale_inverse = param.B_scale_inv;
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_A_SCALE_POINTER,
                                                       &A_scale_inverse, sizeof(A_scale_inverse)));
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_B_SCALE_POINTER,
                                                       &B_scale_inverse, sizeof(B_scale_inverse)));
#if CUBLAS_VERSION >= 120800
      scaling_mode_a = CUBLASLT_MATMUL_MATRIX_SCALE_SCALAR_32F;
      scaling_mode_b = CUBLASLT_MATMUL_MATRIX_SCALE_SCALAR_32F;
#endif  // CUBLAS_VERSION >= 120800
    } else if ((is_mxfp_scaling(inputA->scaling_mode) && is_mxfp_scaling(inputB->scaling_mode))) {
#if CUBLAS_VERSION >= 120800
      NVTE_CHECK(cublas_version() >= 120800,
                 "MXFP8 requires cuBLAS 12.8+, but run-time cuBLAS version is ", cublas_version());
      fp8e8m0 *A_scale_inverse = reinterpret_cast<fp8e8m0 *>(param.A_scale_inv);
      fp8e8m0 *B_scale_inverse = reinterpret_cast<fp8e8m0 *>(param.B_scale_inv);
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_A_SCALE_POINTER,
                                                       &A_scale_inverse, sizeof(A_scale_inverse)));
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_B_SCALE_POINTER,
                                                       &B_scale_inverse, sizeof(B_scale_inverse)));
      scaling_mode_a = CUBLASLT_MATMUL_MATRIX_SCALE_VEC32_UE8M0;
      scaling_mode_b = CUBLASLT_MATMUL_MATRIX_SCALE_VEC32_UE8M0;
      // Workaround for heuristic cache bug in cublasLt. This separates the MXFP8 cache key from non-block scaling.
      // CUBLASLT_MATMUL_DESC_ALPHA_VECTOR_BATCH_STRIDE is unused for block scaling so it's safe to set.
      if (cublas_version() <= 120803) {
        const int64_t dummy_a_vec_stride = 1;
        NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
            operationDesc, CUBLASLT_MATMUL_DESC_ALPHA_VECTOR_BATCH_STRIDE, &dummy_a_vec_stride,
            sizeof(dummy_a_vec_stride)));
      }
#else
      NVTE_ERROR("MXFP8 requires cuBLAS 12.8+, but compile-time cuBLAS version is ",
                 CUBLAS_VERSION);
#endif  // CUBLAS_VERSION >= 120800
    } else if ((inputA->scaling_mode == NVTE_BLOCK_SCALING_1D ||
                inputA->scaling_mode == NVTE_BLOCK_SCALING_2D) &&
               (inputB->scaling_mode == NVTE_BLOCK_SCALING_1D ||
                inputB->scaling_mode == NVTE_BLOCK_SCALING_2D)) {
#if CUBLAS_VERSION >= 120900
      NVTE_CHECK(cublas_version() >= 120900,
                 "FP8 block scaling requires cuBLAS 12.9+, but run-time cuBLAS version is ",
                 cublas_version());
      float *A_scale_inverse = reinterpret_cast<float *>(param.A_scale_inv);
      float *B_scale_inverse = reinterpret_cast<float *>(param.B_scale_inv);
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_A_SCALE_POINTER,
                                                       &A_scale_inverse, sizeof(A_scale_inverse)));
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_B_SCALE_POINTER,
                                                       &B_scale_inverse, sizeof(B_scale_inverse)));
      NVTE_CHECK((!(inputA->scaling_mode == NVTE_BLOCK_SCALING_2D &&
                    inputB->scaling_mode == NVTE_BLOCK_SCALING_2D)),
                 "Only 1D by 1D, 1D by 2D, and 2D by 1D block scaling supported, but got 2D by 2D");
      scaling_mode_a = inputA->scaling_mode == NVTE_BLOCK_SCALING_1D
                           ? CUBLASLT_MATMUL_MATRIX_SCALE_VEC128_32F
                           : CUBLASLT_MATMUL_MATRIX_SCALE_BLK128x128_32F;
      scaling_mode_b = inputB->scaling_mode == NVTE_BLOCK_SCALING_1D
                           ? CUBLASLT_MATMUL_MATRIX_SCALE_VEC128_32F
                           : CUBLASLT_MATMUL_MATRIX_SCALE_BLK128x128_32F;
#else
      NVTE_ERROR("FP8 block scaling requires cuBLAS 12.9+, but compile-time cuBLAS version is ",
                 CUBLAS_VERSION);
#endif  // CUBLAS_VERSION >= 120900
    } else {
      NVTE_ERROR("Not implemented scaling modes: " + to_string(inputA->scaling_mode) + " and  " +
                 to_string(inputB->scaling_mode) + ".");
    }

#if CUBLAS_VERSION >= 120800
    if (cublas_version() >= 120800) {
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_A_SCALE_MODE,
                                                       &scaling_mode_a, sizeof(scaling_mode_a)));
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                       CUBLASLT_MATMUL_DESC_B_SCALE_MODE,
                                                       &scaling_mode_b, sizeof(scaling_mode_b)));
    }
#endif  // CUBLAS_VERSION >= 120800
    if (is_fp8_dtype(outputD->data.dtype)) {
      // Accumulation mode not supported for FP8 output
      C = nullptr;
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
          operationDesc, CUBLASLT_MATMUL_DESC_D_SCALE_POINTER, &D_scale, sizeof(D_scale)));
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
          operationDesc, CUBLASLT_MATMUL_DESC_AMAX_D_POINTER, &D_amax, sizeof(D_amax)));
#if CUBLAS_VERSION >= 120800
      if (cublas_version() >= 120800) {
        // NOTE: In all current cases where FP8 output is supported, the input is
        // scaled identically to the output.
        NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                         CUBLASLT_MATMUL_DESC_D_SCALE_MODE,
                                                         &scaling_mode_a, sizeof(scaling_mode_a)));
      }
#endif  // CUBLAS_VERSION >= 120800
      // For FP8 output, cuBLAS requires C_type to match bias_type and
      // be FP16/BF16
      const cudaDataType_t C_type = bias ? bias_type : CUDA_R_16BF;
      NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Cdesc, C_type, m, n, ldd));
    } else {
      NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Cdesc, D_type, m, n, ldd));
    }
    if (bias) {
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
          operationDesc, CUBLASLT_MATMUL_DESC_BIAS_DATA_TYPE, &bias_type, sizeof(bias_type)));
    }
  } else {
    NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutCreate(&Cdesc, D_type, m, n, ldd));
  }

  if (bias && gelu) {
    if (grad) {
      epilogue = CUBLASLT_EPILOGUE_DGELU_BGRAD;
    } else {
      epilogue = CUBLASLT_EPILOGUE_GELU_AUX_BIAS;
    }
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_BIAS_POINTER, &bias_ptr, sizeof(bias_ptr)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_POINTER,
                                                     &pre_gelu_out, sizeof(pre_gelu_out)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_LD, &ld_gelumat, sizeof(ld_gelumat)));
    const cudaDataType_t aux_type = get_cuda_dtype(outputPreGelu->data.dtype);
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_DATA_TYPE, &aux_type, sizeof(aux_type)));
  } else if (bias) {
    if (grad) {
      // grad output is always input B
      epilogue = CUBLASLT_EPILOGUE_BGRADB;
    } else {
      epilogue = CUBLASLT_EPILOGUE_BIAS;
    }
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_BIAS_POINTER, &bias_ptr, sizeof(bias_ptr)));
  } else if (gelu) {
    if (grad) {
      epilogue = CUBLASLT_EPILOGUE_DGELU;
    } else {
      epilogue = CUBLASLT_EPILOGUE_GELU_AUX;
    }
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc,
                                                     CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_POINTER,
                                                     &pre_gelu_out, sizeof(pre_gelu_out)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_LD, &ld_gelumat, sizeof(ld_gelumat)));
    const cudaDataType_t aux_type = get_cuda_dtype(outputPreGelu->data.dtype);
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE_AUX_DATA_TYPE, &aux_type, sizeof(aux_type)));
  }

  if ((inputA->scaling_mode == NVTE_BLOCK_SCALING_1D) ||
      (inputA->scaling_mode == NVTE_BLOCK_SCALING_2D)) {
    NVTE_CHECK((epilogue == CUBLASLT_EPILOGUE_DEFAULT || epilogue == CUBLASLT_EPILOGUE_BIAS ||
                epilogue == CUBLASLT_EPILOGUE_DGELU),
               "Epilogue requested outside of the available and tested cuBLAS functionality for "
               "float8 block scaled GEMM");
  }

  NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(operationDesc, CUBLASLT_MATMUL_DESC_EPILOGUE,
                                                   &epilogue, sizeof(epilogue)));

  if (counter != nullptr) {
#if !(CUDA_VERSION >= 12020 && CUBLAS_VERSION >= 13000)
    NVTE_ERROR("Atomic GEMM requires CUDA >=12.2.0 and <13.0.0, but compile-time CUDA verson is ",
               CUDA_VERSION);
#endif
#if !(CUBLAS_VERSION >= 120205 && CUBLAS_VERSION < 130000)
    NVTE_ERROR(
        "Atomic GEMM requires cuBLAS >=12.2.5 and <13.0.0, but compile-time cuBLAS verson is ",
        CUBLAS_VERSION);
#endif
#if CUDA_VERSION >= 12020 && CUBLAS_VERSION >= 120205 && CUDA_VERSION < 13000 && \
    CUBLAS_VERSION < 130000
    NVTE_CHECK(cuda::cudart_version() >= 12020 && cuda::cudart_version() < 13000,
               "Atomic GEMM requires CUDA >=12.2.0 and <13.0.0, but run-time CUDA verson is ",
               cuda::cudart_version());
    NVTE_CHECK(cublas_version() >= 120205 && cublas_version() < 130000,
               "Atomic GEMM requires cuBLAS >=12.2.5 and <13.0.0, but run-time cuBLAS verson is ",
               cublas_version());
    if (m_split == 0) m_split = 1;
    if (n_split == 0) n_split = 1;
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_ATOMIC_SYNC_NUM_CHUNKS_D_ROWS, &m_split,
        sizeof(m_split)));
    NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
        operationDesc, CUBLASLT_MATMUL_DESC_ATOMIC_SYNC_NUM_CHUNKS_D_COLS, &n_split,
        sizeof(n_split)));
    if (gemm_producer) {
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
          operationDesc, CUBLASLT_MATMUL_DESC_ATOMIC_SYNC_OUT_COUNTERS_POINTER, &counter,
          sizeof(counter)));
    } else {
      NVTE_CHECK_CUBLAS(cublasLtMatmulDescSetAttribute(
          operationDesc, CUBLASLT_MATMUL_DESC_ATOMIC_SYNC_IN_COUNTERS_POINTER, &counter,
          sizeof(counter)));
    }
#endif
  }

  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceCreate(&preference));
  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceSetAttribute(
      preference, CUBLASLT_MATMUL_PREF_MAX_WORKSPACE_BYTES, &workspaceSize, sizeof(workspaceSize)));
  const auto A_alignment = _getAlignment(reinterpret_cast<uintptr_t>(param.A));
  const auto B_alignment = _getAlignment(reinterpret_cast<uintptr_t>(param.B));
  const auto C_alignment = _getAlignment(reinterpret_cast<uintptr_t>(C));
  const auto D_alignment = _getAlignment(reinterpret_cast<uintptr_t>(D));
  const auto workspace_alignment = _getAlignment(reinterpret_cast<uintptr_t>(workspace));
  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceSetAttribute(
      preference, CUBLASLT_MATMUL_PREF_MIN_ALIGNMENT_A_BYTES, &A_alignment, sizeof(A_alignment)));
  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceSetAttribute(
      preference, CUBLASLT_MATMUL_PREF_MIN_ALIGNMENT_B_BYTES, &B_alignment, sizeof(B_alignment)));
  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceSetAttribute(
      preference, CUBLASLT_MATMUL_PREF_MIN_ALIGNMENT_C_BYTES, &C_alignment, sizeof(C_alignment)));
  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceSetAttribute(
      preference, CUBLASLT_MATMUL_PREF_MIN_ALIGNMENT_D_BYTES, &D_alignment, sizeof(D_alignment)));
  NVTE_CHECK(workspace_alignment % 256 == 0,
             "cuBLAS workspace pointer must be aligned to 256 bytes, got ", workspace_alignment);

  const auto status =
      cublasLtMatmulAlgoGetHeuristic(handle, operationDesc, Adesc, Bdesc, Cdesc, Ddesc, preference,
                                     1, &heuristicResult, &returnedResults);
  NVTE_CHECK(status != CUBLAS_STATUS_NOT_SUPPORTED,
             "Unable to find suitable cuBLAS GEMM algorithm");
  NVTE_CHECK_CUBLAS(status);
  if (returnedResults == 0) NVTE_ERROR("Unable to find any suitable algorithms");

  // D = alpha * (A * B) + beta * C
  NVTE_CHECK_CUBLAS(cublasLtMatmul(handle, operationDesc,
                                   static_cast<const void *>(&one),         /* alpha */
                                   param.A,                                 /* A */
                                   Adesc, param.B,                          /* B */
                                   Bdesc, static_cast<const void *>(&beta), /* beta */
                                   C,                                       /* C */
                                   Cdesc, D,                                /* D */
                                   Ddesc, &heuristicResult.algo,            /* algo */
                                   workspace,                               /* workspace */
                                   workspaceSize, stream));                 /* stream */

  // Update FP8 scale-inv in output tensor
  // Note: This is a WAR for the case when we have fp8 output but D->scale_inv is not allocated.
  // TODO: Changing gemm interface so that D->scale_inv is allocated and the scale_inv can be
  // calculated here.
  if (is_fp8_dtype(outputD->data.dtype) && outputD->scale_inv.dptr) {
    update_tensor_scale_inv(outputD, stream);
  }

  NVTE_CHECK_CUBLAS(cublasLtMatmulPreferenceDestroy(preference));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Ddesc));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Cdesc));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Bdesc));
  NVTE_CHECK_CUBLAS(cublasLtMatrixLayoutDestroy(Adesc));
  NVTE_CHECK_CUBLAS(cublasLtMatmulDescDestroy(operationDesc));
}

}  // namespace transformer_engine

void nvte_cublas_gemm(const NVTETensor A, const NVTETensor B, NVTETensor D, const NVTETensor bias,
                      NVTETensor pre_gelu_out, bool transa, bool transb, bool grad,
                      NVTETensor workspace, bool accumulate, bool use_split_accumulator,
                      int math_sm_count, cudaStream_t stream) {
  NVTE_API_CALL(nvte_cublas_gemm);
  using namespace transformer_engine;
  const Tensor *inputA = convertNVTETensorCheck(A);
  const Tensor *inputB = convertNVTETensorCheck(B);
  Tensor *outputD = convertNVTETensor(D);
  const Tensor *biasTensor = convertNVTETensor(bias);
  Tensor *outputGelu = convertNVTETensor(pre_gelu_out);
  Tensor *wspace = convertNVTETensor(workspace);

  cublas_gemm(inputA, inputB, outputD, biasTensor, outputGelu, (transa) ? CUBLAS_OP_T : CUBLAS_OP_N,
              (transb) ? CUBLAS_OP_T : CUBLAS_OP_N, grad, wspace->data.dptr, wspace->data.shape[0],
              accumulate, use_split_accumulator, math_sm_count, 0, 0, false, nullptr, stream);
}

void nvte_cublas_atomic_gemm(const NVTETensor A, const NVTETensor B, NVTETensor D,
                             const NVTETensor bias, NVTETensor pre_gelu_out, bool transa,
                             bool transb, bool grad, NVTETensor workspace, bool accumulate,
                             bool use_split_accumulator, int math_sm_count, int m_split,
                             int n_split, bool gemm_producer, const NVTETensor counter,
                             cudaStream_t stream) {
  NVTE_API_CALL(nvte_cublas_atomic_gemm);
  using namespace transformer_engine;

  // Check CUDA and cuBLAS versions
#if !(CUDA_VERSION >= 12020 && CUBLAS_VERSION >= 13000)
  NVTE_ERROR("Atomic GEMM requires CUDA >=12.2.0 and <13.0.0, but compile-time CUDA verson is ",
             CUDA_VERSION);
#endif
#if !(CUBLAS_VERSION >= 120205 && CUBLAS_VERSION < 130000)
  NVTE_ERROR("Atomic GEMM requires cuBLAS >=12.2.5 and <13.0.0, but compile-time cuBLAS verson is ",
             CUBLAS_VERSION);
#endif
  NVTE_CHECK(cuda::cudart_version() >= 12020 && cuda::cudart_version() < 13000,
             "Atomic GEMM requires CUDA version >=12.2.0 and <13.0.0, but run-time CUDA verson is ",
             cuda::cudart_version());
  NVTE_CHECK(
      cublas_version() >= 120205 && cublas_version() < 130000,
      "Atomic GEMM requires cuBLAS version >=12.2.5 and <13.0.0, but run-time cuBLAS verson is ",
      cublas_version());

  const Tensor *inputA = convertNVTETensorCheck(A);
  const Tensor *inputB = convertNVTETensorCheck(B);
  Tensor *outputD = convertNVTETensor(D);
  const Tensor *biasTensor = convertNVTETensor(bias);
  Tensor *outputGelu = convertNVTETensor(pre_gelu_out);
  const Tensor *inputCounter = convertNVTETensor(counter);
  Tensor *wspace = convertNVTETensor(workspace);

  NVTE_CHECK(is_delayed_tensor_scaling(inputA->scaling_mode) &&
                 is_delayed_tensor_scaling(inputB->scaling_mode),
             "Atomic GEMM only supports delayed scaling.");
  cublas_gemm(inputA, inputB, outputD, biasTensor, outputGelu, (transa) ? CUBLAS_OP_T : CUBLAS_OP_N,
              (transb) ? CUBLAS_OP_T : CUBLAS_OP_N, grad, wspace->data.dptr, wspace->data.shape[0],
              accumulate, use_split_accumulator, math_sm_count, m_split, n_split, gemm_producer,
              inputCounter, stream);
}

void nvte_multi_stream_cublas_gemm(const NVTETensor *A, const NVTETensor *B, NVTETensor *D,
                                   const NVTETensor *bias, NVTETensor *pre_gelu_out,
                                   const int num_gemms, bool transa, bool transb, bool grad,
                                   NVTETensor *workspace, bool accumulate,
                                   bool use_split_accumulator, int math_sm_count,
                                   cudaStream_t stream) {
  NVTE_API_CALL(nvte_multi_stream_cublas_gemm);
  using namespace transformer_engine;

  int num_streams = nvte_get_num_compute_streams();

  int num_stream_used = std::min(num_streams, num_gemms);
  // wait for current stream to finish
  NVTE_CHECK_CUDA(cudaEventRecord(detail::get_compute_stream_event(0), stream));
  for (int s = 0; s < num_stream_used; s++) {
    NVTE_CHECK_CUDA(
        cudaStreamWaitEvent(detail::get_compute_stream(s), detail::get_compute_stream_event(0)));
  }

  for (int i = 0; i < num_gemms; i++) {
    nvte_cublas_gemm(A[i], B[i], D[i], bias[i], pre_gelu_out[i], transa, transb, grad,
                     workspace[i % num_streams], accumulate, use_split_accumulator, math_sm_count,
                     detail::get_compute_stream(i % num_streams));
  }

  // record events on compute streams
  for (int s = 0; s < num_stream_used; s++) {
    NVTE_CHECK_CUDA(
        cudaEventRecord(detail::get_compute_stream_event(s), detail::get_compute_stream(s)));
  }
  // wait for all compute streams to finish
  for (int s = 0; s < num_stream_used; s++) {
    NVTE_CHECK_CUDA(cudaStreamWaitEvent(stream, detail::get_compute_stream_event(s)));
  }
}

namespace transformer_engine {

using cublasHandleManager = detail::HandleManager<cublasLtHandle_t, CreateCublasHandle>;

void nvte_cublas_handle_init() { auto _ = cublasHandleManager::Instance().GetHandle(); }

}  //  namespace transformer_engine
