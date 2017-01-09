#define CUB_STDERR

#include "cuda_helpers.h"
#include "cuda_runtime.h"
#include "garden.h"
#include "objective.h"
#include "param.h"
#include <algorithm>
#include <cub/cub.cuh>
#include <limits>
#include <math.h>
#include <random>
#include <stdio.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/host_vector.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/scan.h>
#include <thrust/sort.h>
#include <thrust/system/cuda/execution_policy.h>
#include <thrust/system/cuda/experimental/pinned_allocator.h>
#include <trove/aos.h>
#include <trove/ptr.h>

namespace arboretum {
namespace core {
using namespace thrust;
using namespace thrust::cuda;
using thrust::host_vector;
using thrust::device_vector;
using thrust::cuda::experimental::pinned_allocator;

union my_atomics {
  float floats[2];              // floats[0] = maxvalue
  unsigned int ints[2];         // ints[1] = maxindex
  unsigned long long int ulong; // for atomic update
};

struct GainFunctionParameters {
  const unsigned int min_leaf_size;
  const float hess;
  const float gamma;
  const float lambda;
  const float alpha;
  GainFunctionParameters(const unsigned int min_leaf_size, const float hess,
                         const float gamma, const float lambda,
                         const float alpha)
      : min_leaf_size(min_leaf_size), hess(hess), gamma(gamma), lambda(lambda),
        alpha(alpha) {}
};

__forceinline__ __device__ unsigned long long int
updateAtomicMax(unsigned long long int *address, float val1,
                unsigned int val2) {
  my_atomics loc, loctest;
  loc.floats[0] = val1;
  loc.ints[1] = val2;
  loctest.ulong = *address;
  while (loctest.floats[0] < val1)
    loctest.ulong = atomicCAS(address, loctest.ulong, loc.ulong);
  return loctest.ulong;
}

template <class type1>
__global__ void
gather_kernel_simple(const unsigned int *const __restrict__ position,
                     const type1 *const __restrict__ in1, type1 *out1,
                     const size_t n) {
  for (size_t i = blockDim.x * blockIdx.x + threadIdx.x; i < n;
       i += gridDim.x * blockDim.x) {
    out1[i] = in1[position[i]];
  }
}

template <class T>
__global__ void gather(const unsigned int *const __restrict__ position,
                        T *in, T *out,
                       const size_t n) {
  for (size_t i = blockDim.x * blockIdx.x + threadIdx.x; i < n;
       i += gridDim.x * blockDim.x) {
    const unsigned int index = position[i];
    trove::coalesced_ptr<T> s(in);
    trove::coalesced_ptr<T> r(out);
    T data = s[index];
    r[index] = data;
  }
}

template <class type1>
__global__ void
gather_kernel_temp(const unsigned int *const __restrict__ position,
                   const type1 *const __restrict__ data, type1 *out, type1 *tmp,
                   const size_t n) {
  for (size_t i = blockDim.x * blockIdx.x + threadIdx.x; i < n;
       i += gridDim.x * blockDim.x) {
    tmp[i] = data[position[i]];
  }

  __syncthreads();

  for (size_t i = blockDim.x * blockIdx.x + threadIdx.x; i < n;
       i += gridDim.x * blockDim.x) {
    out[i] = tmp[i];
  }
}

__forceinline__ __device__ __host__ float
gain_func(const double2 left_sum, const double2 total_sum,
          const size_t left_count, const size_t total_count,
          const GainFunctionParameters &params) {
  const double2 right_sum = total_sum - left_sum;
  if (left_count >= params.min_leaf_size &&
      (total_count - left_count) >= params.min_leaf_size &&
      std::abs(left_sum.y) >= params.hess &&
      std::abs(right_sum.y) >= params.hess) {
    const float l = (left_sum.x * left_sum.x) / (left_sum.y + params.lambda);
    const float r = (right_sum.x * right_sum.x) / (right_sum.y + params.lambda);
    const float p = (total_sum.x * total_sum.x) / (total_sum.y + params.lambda);
    return l + r - p;
  } else {
    return 0.0;
  }
}

__forceinline__ __device__ __host__ float
gain_func(const float2 left_sum, const float2 total_sum,
          const size_t left_count, const size_t total_count,
          const GainFunctionParameters &params) {
  const float2 right_sum = total_sum - left_sum;
  if (left_count >= params.min_leaf_size &&
      (total_count - left_count) >= params.min_leaf_size &&
      std::abs(left_sum.y) >= params.hess &&
      std::abs(right_sum.y) >= params.hess) {
    const float l = (left_sum.x * left_sum.x) / (left_sum.y + params.lambda);
    const float r = (right_sum.x * right_sum.x) / (right_sum.y + params.lambda);
    const float p = (total_sum.x * total_sum.x) / (total_sum.y + params.lambda);
    return l + r - p;
  } else {
    return 0.0;
  }
}

__forceinline__ __device__ __host__ float
gain_func(const float left_sum, const float total_sum, const size_t left_count,
          const size_t total_count, const GainFunctionParameters &params) {
  const size_t right_count = total_count - left_count;
  if (left_count >= params.min_leaf_size &&
      right_count >= params.min_leaf_size) {
    const float right_sum = total_sum - left_sum;
    const float l = left_sum * left_sum / (left_count + params.lambda);
    const float r = right_sum * right_sum / (right_count + params.lambda);
    const float p = total_sum * total_sum / (total_count + params.lambda);
    return l + r - p;
  } else {
    return 0.0;
  }
}

__forceinline__ __device__ __host__ float
gain_func(const double left_sum, const double total_sum,
          const size_t left_count, const size_t total_count,
          const GainFunctionParameters &params) {
  const size_t right_count = total_count - left_count;
  if (left_count >= params.min_leaf_size &&
      right_count >= params.min_leaf_size) {
    const double right_sum = total_sum - left_sum;
    const double l = left_sum * left_sum / (left_count + params.lambda);
    const double r = right_sum * right_sum / (right_count + params.lambda);
    const double p = total_sum * total_sum / (total_count + params.lambda);
    return l + r - p;
  } else {
    return 0.0;
  }
}

template <class node_type, typename sum_type>
__global__ void
gain_kernel(const sum_type *const __restrict__ left_sum,
            const float *const __restrict__ fvalues,
            const node_type *const __restrict__ segments,
            const sum_type *const __restrict__ parent_sum_iter,
            const unsigned int *const __restrict__ parent_count_iter,
            const size_t n, const GainFunctionParameters parameters,
            my_atomics *res) {
  for (unsigned int i = blockDim.x * blockIdx.x + threadIdx.x; i < n;
       i += gridDim.x * blockDim.x) {
    const float fvalue = fvalues[i + 1];
    const float fvalue_prev = fvalues[i];
    if (fvalue != fvalue_prev) {
      const node_type segment = segments[i];

      const sum_type left_sum_offset = parent_sum_iter[segment];
      const sum_type left_sum_value = left_sum[i] - left_sum_offset;

      const size_t left_count_offset = parent_count_iter[segment];
      const size_t left_count_value = i - left_count_offset;

      const sum_type total_sum = parent_sum_iter[segment + 1] - left_sum_offset;
      const size_t total_count =
          parent_count_iter[segment + 1] - left_count_offset;

      const float gain = gain_func(left_sum_value, total_sum, left_count_value,
                                   total_count, parameters);
      if (gain > 0.0) {
        updateAtomicMax(&(res[segment].ulong), gain, i);
      }
    }
  }
}

template <typename node_type, typename grad_type, typename sum_type>
class TaylorApproximationBuilder : public GardenBuilderBase {
public:
  TaylorApproximationBuilder(const TreeParam &param, const io::DataMatrix *data,
                             const InternalConfiguration &config,
                             const ApproximatedObjective<grad_type> *objective,
                             const bool verbose)
      : verbose(verbose), rnd(config.seed), overlap_depth(config.overlap),
        param(param), gain_param(param.min_leaf_size, param.min_child_weight,
                                 param.gamma, param.lambda, param.alpha),
        objective(objective),
        sparse_stat(data->columns_sparse,
                    std::vector<unsigned int>(1 << (param.depth - 2), 0)) {

    grad_d.resize(data->rows);

    active_fids.resize(data->columns);

    const int lenght = 1 << param.depth;

    int minGridSize;
    cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSizeGain,
                                       gain_kernel<node_type, sum_type>, 0, 0);
    gridSizeGain = (data->rows + blockSizeGain - 1) / blockSizeGain;

    minGridSize = 0;

    cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSizeGather,
                                       gather_kernel_simple<node_type>, 0, 0);
    gridSizeGather = (data->rows + blockSizeGather - 1) / blockSizeGather;

    row2Node.resize(data->rows);
    _rowIndex2Node.resize(data->rows, 0);
    _bestSplit.resize(1 << (param.depth - 2));
    _nodeStat.resize(1 << (param.depth - 2),
                     NodeStat<sum_type>(data->columns_sparse));

    parent_node_sum.resize(lenght + 1);
    parent_node_count.resize(lenght + 1);
    parent_node_sum_h.resize(lenght + 1);
    parent_node_count_h.resize(lenght + 1);

    for (size_t i = 0; i < overlap_depth; ++i) {
      cudaStream_t s;
      cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking);
      streams[i] = s;
      sum[i] = device_vector<sum_type>(data->rows);
      segments[i] = device_vector<node_type>(data->rows);
      segments_sorted[i] = device_vector<node_type>(data->rows);
      fvalue[i] = device_vector<float>(data->rows + 1);
      fvalue[i][0] = -std::numeric_limits<float>::infinity();
      position[i] = device_vector<unsigned int>(data->rows);
      position_sorted[i] = device_vector<unsigned int>(data->rows);
      grad_sorted[i] = device_vector<grad_type>(data->rows);
      temp_bytes_allocated[i] = 0;
      CubDebugExit(cudaMalloc(&(results[i]), sizeof(my_atomics) * lenght));
      CubDebugExit(
          cudaMallocHost(&(results_h[i]), sizeof(my_atomics) * lenght));
    }
    {
      cudaFuncSetCacheConfig(gather_kernel_simple<float>,
                             cudaFuncCachePreferL1);
      cudaFuncSetCacheConfig(gather_kernel_simple<node_type>,
                             cudaFuncCachePreferL1);
      cudaFuncSetCacheConfig(gather_kernel_simple<grad_type>,
                             cudaFuncCachePreferL1);
      cudaFuncSetCacheConfig(gather_kernel_temp<float>, cudaFuncCachePreferL1);
      cudaFuncSetCacheConfig(gain_kernel<node_type, sum_type>,
                             cudaFuncCachePreferL1);
    }
    {
      size_t max = 0;

      size_t temp_storage_bytes = 0;

      CubDebugExit(cub::DeviceRadixSort::SortPairs(
          NULL, temp_storage_bytes,
          thrust::raw_pointer_cast(segments[0].data()),
          thrust::raw_pointer_cast(segments_sorted[0].data()),
          thrust::raw_pointer_cast(position[0].data()),
          thrust::raw_pointer_cast(position_sorted[0].data()), data->rows, 0,
          1));

      max = std::max(max, temp_storage_bytes);

      temp_storage_bytes = 0;

      sum_type initial_value;
      init(initial_value);
      cub::Sum sum_op;

      CubDebugExit(cub::DeviceScan::ExclusiveScan(
          NULL, temp_storage_bytes,
          thrust::raw_pointer_cast(grad_sorted[0].data()),
          thrust::raw_pointer_cast(sum[0].data()), sum_op, initial_value,
          data->rows));

      max = std::max(max, temp_storage_bytes);

      temp_storage_bytes = sizeof(float) * data->rows;
      max = std::max(max, temp_storage_bytes);

      temp_storage_bytes = sizeof(grad_type) * data->rows;
      max = std::max(max, temp_storage_bytes);

      temp_storage_bytes = sizeof(node_type) * data->rows;
      max = std::max(max, temp_storage_bytes);

      for (size_t i = 0; i < overlap_depth; ++i) {
        AllocateMemoryIfRequire(i, max);
      }
    }
  }

  virtual ~TaylorApproximationBuilder() {
    for (auto i = 0; i < overlap_depth; ++i) {
      CubDebugExit(cudaFree(temp_bytes[i]));
      CubDebugExit(cudaFree(results[i]));
      CubDebugExit(cudaFreeHost(results_h[i]));
      cudaStreamDestroy(streams[i]);
    }
    delete[] sum;
    delete[] segments;
    delete[] segments_sorted;
    delete[] fvalue;
    delete[] position;
    delete[] position_sorted;
    delete[] grad_sorted;
    delete[] temp_bytes;
  }

  virtual size_t MemoryRequirementsPerRecord() override {
    return (sizeof(node_type) +    // node
            sizeof(grad_type) +    // grad_sorted
            sizeof(sum_type) +     // sum
            sizeof(node_type) +    // segments
            sizeof(node_type) +    // segments_sorted
            sizeof(float) +        // fvalue
            sizeof(unsigned int) + // position
            sizeof(unsigned int)   // position sorted
            ) *
           overlap_depth;
  }

  virtual void InitGrowingTree(const size_t columns,
                               const size_t sparse_columns) override {
    int take = (int)(param.colsample_bytree * columns);
    if (take == 0) {
      printf("colsample_bytree is too small %f for %ld columns \n",
             param.colsample_bytree, columns);
      throw "colsample_bytree is too small";
    }
    take = (int)(param.colsample_bytree * param.colsample_bylevel * columns);
    if (take == 0) {
      printf("colsample_bytree and colsample_bylevel are too small %f %f for "
             "%ld columns \n",
             param.colsample_bytree, param.colsample_bylevel, columns);
      throw "colsample_bytree and colsample_bylevel are too small";
    }

    for (size_t i = 0; i < columns; ++i) {
      active_fids[i] = i;
    }

    for (size_t i = 0; i < sparse_columns; ++i) {
      std::fill(sparse_stat[i].begin(), sparse_stat[i].end(), 0);
    }

    shuffle(active_fids.begin(), active_fids.end(), rnd);

    std::fill(_rowIndex2Node.begin(), _rowIndex2Node.end(), 0);
    for (size_t i = 0; i < _nodeStat.size(); ++i) {
      _nodeStat[i].Clean();
    }
    for (size_t i = 0; i < _bestSplit.size(); ++i) {
      _bestSplit[i].Clean();
    }
  }

  virtual void InitTreeLevel(const int level, const size_t columns) override {
    int take = (int)(param.colsample_bytree * columns);
    shuffle(active_fids.begin(), active_fids.begin() + take, rnd);
  }

  virtual void GrowTree(RegTree *tree, const io::DataMatrix *data,
                        const unsigned short label) override {

    cudaMemcpyAsync(
        thrust::raw_pointer_cast(grad_d.data()),
        thrust::raw_pointer_cast(objective->grad.data() + label * data->rows),
        data->rows * sizeof(grad_type), cudaMemcpyHostToDevice, streams[0]);

    grad_slice = const_cast<grad_type *>(
        thrust::raw_pointer_cast(objective->grad.data() + label * data->rows));

    InitGrowingTree(data->columns, data->columns_sparse);

    for (unsigned int i = 0; (i + 1) < param.depth; ++i) {
      InitTreeLevel(i, data->columns);
      UpdateNodeStat(i, data, tree);
      FindBestSplits(i, data);
      UpdateTree(i, tree);
      UpdateNodeIndex(i, data, tree);
    }

    UpdateLeafWeight(tree);
  }

  virtual void PredictByGrownTree(RegTree *tree, io::DataMatrix *data,
                                  std::vector<float> &out) const override {
    tree->Predict(data, _rowIndex2Node, out);
  }

private:
  bool verbose;
  std::default_random_engine rnd;
  std::vector<unsigned int> active_fids;
  const unsigned short overlap_depth;
  const TreeParam param;
  const GainFunctionParameters gain_param;
  grad_type *grad_slice;
  const ApproximatedObjective<grad_type> *objective;
  host_vector<node_type,
              thrust::cuda::experimental::pinned_allocator<node_type>>
      _rowIndex2Node;
  std::vector<NodeStat<sum_type>> _nodeStat;
  std::vector<Split<sum_type>> _bestSplit;

  device_vector<sum_type> *sum = new device_vector<sum_type>[ overlap_depth ];
  device_vector<node_type> *segments =
      new device_vector<node_type>[ overlap_depth ];
  device_vector<node_type> *segments_sorted =
      new device_vector<node_type>[ overlap_depth ];
  device_vector<float> *fvalue = new device_vector<float>[ overlap_depth ];
  device_vector<unsigned int> *position =
      new device_vector<unsigned int>[ overlap_depth ];
  device_vector<unsigned int> *position_sorted =
      new device_vector<unsigned int>[ overlap_depth ];
  device_vector<grad_type> *grad_sorted =
      new device_vector<grad_type>[ overlap_depth ];
  cudaStream_t *streams = new cudaStream_t[overlap_depth];
  device_vector<grad_type> grad_d;
  device_vector<node_type> row2Node;
  device_vector<sum_type> parent_node_sum;
  device_vector<unsigned int> parent_node_count;
  host_vector<sum_type> parent_node_sum_h;
  host_vector<unsigned int> parent_node_count_h;
  size_t *temp_bytes_allocated = new size_t[overlap_depth];
  void **temp_bytes = new void *[overlap_depth];
  my_atomics **results = new my_atomics *[overlap_depth];
  my_atomics **results_h = new my_atomics *[overlap_depth];
  std::vector<std::vector<unsigned int>> sparse_stat;

  int blockSizeGain;
  int gridSizeGain;

  int blockSizeGather;
  int gridSizeGather;

  inline void AllocateMemoryIfRequire(const size_t circular_fid,
                                      const size_t bytes) {
    if (temp_bytes_allocated[circular_fid] == 0) {
      CubDebugExit(cudaMalloc(&(temp_bytes[circular_fid]), bytes));
      temp_bytes_allocated[circular_fid] = bytes;
    } else if (temp_bytes_allocated[circular_fid] < bytes) {
      CubDebugExit(cudaFree(temp_bytes[circular_fid]));
      CubDebugExit(cudaMalloc(&(temp_bytes[circular_fid]), bytes));
      temp_bytes_allocated[circular_fid] = bytes;
    }
  }

  void FindBestSplits(const int level, const io::DataMatrix *data) {

    cudaMemcpyAsync(thrust::raw_pointer_cast((row2Node.data())),
                    thrust::raw_pointer_cast(_rowIndex2Node.data()),
                    data->rows * sizeof(node_type), cudaMemcpyHostToDevice,
                    streams[0]);

    const size_t lenght = 1 << level;

    {
      init(parent_node_sum_h[0]);
      parent_node_count_h[0] = 0;

      for (size_t i = 0; i < lenght; ++i) {
        parent_node_count_h[i + 1] =
            parent_node_count_h[i] + _nodeStat[i].count;
        parent_node_sum_h[i + 1] = parent_node_sum_h[i] + _nodeStat[i].sum_grad;
      }
      parent_node_sum = parent_node_sum_h;
      parent_node_count = parent_node_count_h;
    }

    unsigned int take = (unsigned int)(param.colsample_bylevel *
                                       param.colsample_bytree * data->columns);

    cudaStreamSynchronize(streams[0]);

    for (size_t j = 0; j < take; ++j) {

      for (size_t i = 0; i < overlap_depth && (j + i) < take; ++i) {

        if (j != 0 && (i + 1) < overlap_depth) {
          continue;
        }

        size_t active_fid = active_fids[j + i];
        size_t circular_fid = (j + i) % overlap_depth;

        if (active_fid < data->columns_dense)
          ProcessDenceFeature(active_fid, circular_fid, level, data);
        else
          ProcessSparseFeature(active_fid - data->columns_dense, circular_fid,
                               level, data);
      }

      size_t circular_fid = j % overlap_depth;

      cudaStream_t s = streams[circular_fid];

      cudaStreamSynchronize(s);

      if (active_fids[j] < data->columns_dense) {
        GetBestSplitForDenceFeature(active_fids[j], circular_fid, lenght);
      } else {
        GetBestSplitForSparseFeature(active_fids[j] - data->columns_dense,
                                     data->columns_dense, circular_fid, lenght);
      }
    }

    for (size_t i = 0; i < lenght; ++i) {
      Split<sum_type> &split = _bestSplit[i];

      if (split.fid < 0) {
        NodeStat<sum_type> &node_stat = _nodeStat[i];
        _bestSplit[i].gain = 0.0;
        _bestSplit[i].fid = 0;
        _bestSplit[i].split_value = std::numeric_limits<float>::infinity();
        _bestSplit[i].count = node_stat.count;
        _bestSplit[i].sum_grad = node_stat.sum_grad;
      }
    }
  }

  inline void GetBestSplitForDenceFeature(const int active_fid,
                                          const size_t circular_fid,
                                          const size_t lenght) {
    for (size_t i = 0; i < lenght; ++i) {
      if (_nodeStat[i].count <= 0)
        continue;
      if (results_h[circular_fid][i].floats[0] > _bestSplit[i].gain) {
        const int index_value = results_h[circular_fid][i].ints[1];
        const sum_type s = sum[circular_fid][index_value];
        if (!_isnan(s)) {
          const float fvalue_prev_val = fvalue[circular_fid][index_value];
          const float fvalue_val = fvalue[circular_fid][index_value + 1];
          const size_t count_val =
              results_h[circular_fid][i].ints[1] - parent_node_count_h[i];

          const sum_type sum_val = s - parent_node_sum_h[i];
          _bestSplit[i].fid = active_fid;
          _bestSplit[i].gain = results_h[circular_fid][i].floats[0];
          _bestSplit[i].split_value = (fvalue_prev_val + fvalue_val) * 0.5;
          _bestSplit[i].count = count_val;
          _bestSplit[i].sum_grad = sum_val;
        } else {
          if (verbose)
            printf("sum is nan(probably infinity), consider increasing the "
                   "accuracy \n");
        }
      }
    }
  }

  inline void GetBestSplitForSparseFeature(const int active_fid,
                                           const size_t columns_dense,
                                           const size_t circular_fid,
                                           const size_t lenght) {
    for (size_t i = 0; i < lenght; ++i) {
      if (sparse_stat[active_fid][i] == 0)
        continue;
      sum_type sum_true = sum[circular_fid][i];
      if (!_isnan(sum_true)) {
        float gain = gain_func(sum_true, _nodeStat[i].sum_grad,
                               sparse_stat[active_fid][i], _nodeStat[i].count,
                               gain_param);
        if (gain > _bestSplit[i].gain) {
          _bestSplit[i].fid = active_fid + columns_dense;
          _bestSplit[i].gain = gain;
          _bestSplit[i].split_by_true = true;
          _bestSplit[i].count = sparse_stat[active_fid][i];
          _bestSplit[i].sum_grad = sum_true;
        }

      } else {
        if (verbose)
          printf("sum is nan(probably infinity), consider increasing the "
                 "accuracy \n");
      }
    }
  }

  inline void ProcessDenceFeature(const size_t active_fid,
                                  const size_t circular_fid, const int level,
                                  const io::DataMatrix *data) {

    size_t lenght = 1 << level;

    cudaStream_t s = streams[circular_fid];

    device_vector<float> *fvalue_tmp = NULL;

    cudaMemsetAsync(results[circular_fid], 0, lenght * sizeof(my_atomics), s);

    if (data->data_device[active_fid].size() > 0) {
      fvalue_tmp =
          const_cast<device_vector<float> *>(&(data->data_device[active_fid]));
    } else {
      cudaMemcpyAsync(
          thrust::raw_pointer_cast((&fvalue[circular_fid].data()[1])),
          thrust::raw_pointer_cast(data->data[active_fid].data()),
          data->rows * sizeof(float), cudaMemcpyHostToDevice, s);
      cudaStreamSynchronize(s);
      fvalue_tmp = const_cast<device_vector<float> *>(&(fvalue[circular_fid]));
    }

    device_vector<unsigned int> *index_tmp = NULL;

    if (data->index_device[active_fid].size() > 0) {
      index_tmp = const_cast<device_vector<unsigned int> *>(
          &(data->index_device[active_fid]));
    } else {
      cudaMemcpyAsync(thrust::raw_pointer_cast(position[circular_fid].data()),
                      thrust::raw_pointer_cast(data->index[active_fid].data()),
                      data->rows * sizeof(unsigned int), cudaMemcpyHostToDevice,
                      s);
      cudaStreamSynchronize(s);
      index_tmp =
          const_cast<device_vector<unsigned int> *>(&(position[circular_fid]));
    }

    gather_kernel_simple<<<gridSizeGather, blockSizeGather, 0, s>>>(
        thrust::raw_pointer_cast(index_tmp->data()),
        thrust::raw_pointer_cast(row2Node.data()),
        thrust::raw_pointer_cast(segments[circular_fid].data()), data->rows);

    size_t temp_storage_bytes = 0;

    CubDebugExit(cub::DeviceRadixSort::SortPairs(
        NULL, temp_storage_bytes,
        thrust::raw_pointer_cast(segments[circular_fid].data()),
        thrust::raw_pointer_cast(segments_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(index_tmp->data()),
        thrust::raw_pointer_cast(position_sorted[circular_fid].data()),
        data->rows, 0, level + 1, s));

    CubDebugExit(cub::DeviceRadixSort::SortPairs(
        temp_bytes[circular_fid], temp_storage_bytes,
        thrust::raw_pointer_cast(segments[circular_fid].data()),
        thrust::raw_pointer_cast(segments_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(index_tmp->data()),
        thrust::raw_pointer_cast(position_sorted[circular_fid].data()),
        data->rows, 0, level + 1, s));

    gather<<<gridSizeGather, blockSizeGather, 0, s>>>(
        thrust::raw_pointer_cast(position_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(grad_d.data()),
        thrust::raw_pointer_cast(grad_sorted[circular_fid].data()), data->rows);

    gather_kernel_temp<<<gridSizeGather, blockSizeGather, 0, s>>>(
        thrust::raw_pointer_cast(position_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(fvalue_tmp->data() + 1),
        thrust::raw_pointer_cast(fvalue[circular_fid].data() + 1),
        (float *)temp_bytes[circular_fid], data->rows);

    sum_type initial_value;
    init(initial_value);
    cub::Sum sum_op;

    temp_storage_bytes = 0;

    CubDebugExit(cub::DeviceScan::ExclusiveScan(
        NULL, temp_storage_bytes,
        thrust::raw_pointer_cast(grad_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(sum[circular_fid].data()), sum_op,
        initial_value, data->rows, s));

    CubDebugExit(cub::DeviceScan::ExclusiveScan(
        temp_bytes[circular_fid], temp_storage_bytes,
        thrust::raw_pointer_cast(grad_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(sum[circular_fid].data()), sum_op,
        initial_value, data->rows, s));

    temp_storage_bytes = 0;

    gain_kernel<<<gridSizeGain, blockSizeGain, 0, s>>>(
        thrust::raw_pointer_cast(sum[circular_fid].data()),
        thrust::raw_pointer_cast(fvalue[circular_fid].data()),
        thrust::raw_pointer_cast(segments_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(parent_node_sum.data()),
        thrust::raw_pointer_cast(parent_node_count.data()), data->rows,
        gain_param, results[circular_fid]);

    cudaMemcpyAsync(results_h[circular_fid], results[circular_fid],
                    lenght * sizeof(my_atomics), cudaMemcpyDeviceToHost, s);
  }

  inline void ProcessSparseFeature(const size_t active_fid,
                                   const size_t circular_fid, const int level,
                                   const io::DataMatrix *data) {
    const size_t lenght = 1 << level;
    const size_t feature_size = data->lil_column[active_fid].size();

    cudaStream_t s = streams[circular_fid];

    device_vector<unsigned int> *index_tmp = NULL;

    if (data->lil_column_device[active_fid].size() > 0) {
      index_tmp = const_cast<device_vector<unsigned int> *>(
          &(data->lil_column_device[active_fid]));
    } else {
      cudaMemcpyAsync(
          thrust::raw_pointer_cast(position[circular_fid].data()),
          thrust::raw_pointer_cast(data->lil_column[active_fid].data()),
          feature_size * sizeof(unsigned int), cudaMemcpyHostToDevice, s);
      cudaStreamSynchronize(s);
      index_tmp =
          const_cast<device_vector<unsigned int> *>(&(position[circular_fid]));
    }

    gather_kernel_simple<<<gridSizeGather, blockSizeGather, 0, s>>>(
        thrust::raw_pointer_cast(index_tmp->data()),
        thrust::raw_pointer_cast(row2Node.data()),
        thrust::raw_pointer_cast(segments[circular_fid].data()), feature_size);

    size_t temp_storage_bytes = 0;

    CubDebugExit(cub::DeviceRadixSort::SortPairs(
        NULL, temp_storage_bytes,
        thrust::raw_pointer_cast(segments[circular_fid].data()),
        thrust::raw_pointer_cast(segments_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(index_tmp->data()),
        thrust::raw_pointer_cast(position_sorted[circular_fid].data()),
        feature_size, 0, level + 1, s));

    CubDebugExit(cub::DeviceRadixSort::SortPairs(
        temp_bytes[circular_fid], temp_storage_bytes,
        thrust::raw_pointer_cast(segments[circular_fid].data()),
        thrust::raw_pointer_cast(segments_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(index_tmp->data()),
        thrust::raw_pointer_cast(position_sorted[circular_fid].data()),
        feature_size, 0, level + 1, s));

    gather<<<gridSizeGather, blockSizeGather, 0, s>>>(
        thrust::raw_pointer_cast(position_sorted[circular_fid].data()),
        thrust::raw_pointer_cast(grad_d.data()),
        thrust::raw_pointer_cast(grad_sorted[circular_fid].data()),
        feature_size);

    size_t offset = 0;
    temp_storage_bytes = 0;

    for (size_t i = 0; i < lenght; ++i) {
      if (sparse_stat[active_fid][i] == 0)
        continue;

      temp_storage_bytes = 0;

      CubDebugExit(cub::DeviceReduce::Sum(
          NULL, temp_storage_bytes,
          thrust::raw_pointer_cast(grad_sorted[circular_fid].data() + offset),
          thrust::raw_pointer_cast(sum[circular_fid].data() + i),
          sparse_stat[active_fid][i], s));

      CubDebugExit(cub::DeviceReduce::Sum(
          temp_bytes[circular_fid], temp_storage_bytes,
          thrust::raw_pointer_cast(grad_sorted[circular_fid].data() + offset),
          thrust::raw_pointer_cast(sum[circular_fid].data() + i),
          sparse_stat[active_fid][i], s));

      offset += sparse_stat[active_fid][i];
    }
  }

  void UpdateNodeStat(const int level, const io::DataMatrix *data,
                      const RegTree *tree) {
    if (level != 0) {

      const unsigned int offset = Node::HeapOffset(level);
      const unsigned int offset_next = Node::HeapOffset(level + 1);
      std::vector<NodeStat<sum_type>> tmp(
          _nodeStat.size(), NodeStat<sum_type>(data->columns_sparse));
      std::copy(_nodeStat.begin(), _nodeStat.end(), tmp.begin());

      size_t len = 1 << (level - 1);

      for (size_t i = 0; i < len; ++i) {

        _nodeStat[tree->ChildNode(i + offset, true) - offset_next].count =
            _bestSplit[i].count;
        _nodeStat[tree->ChildNode(i + offset, true) - offset_next].sum_grad =
            _bestSplit[i].sum_grad;

        _nodeStat[tree->ChildNode(i + offset, false) - offset_next].count =
            tmp[i].count - _bestSplit[i].count;

        _nodeStat[tree->ChildNode(i + offset, false) - offset_next].sum_grad =
            tmp[i].sum_grad - _bestSplit[i].sum_grad;
      }

      for (size_t i = 0; i < data->columns_sparse; ++i) {
        std::fill(sparse_stat[i].begin(), sparse_stat[i].end(), 0);
      }

      if (data->columns_sparse > 0) {
#pragma omp parallel
        {
          std::vector<std::vector<unsigned int>> temp_stat(
              data->columns_sparse,
              std::vector<unsigned int>(1 << (param.depth - 2), 0));

#pragma omp for simd
          for (size_t i = 0; i < data->rows; ++i) {
            node_type node = _rowIndex2Node[i];
            const size_t len = data->lil_row[i].size();

            for (size_t j = 0; j < len; ++j) {
              temp_stat[data->lil_row[i][j] - data->columns_dense][node] += 1;
            }
          }

#pragma omp critical
          {
            for (size_t i = 0; i < temp_stat.size(); ++i) {
              for (size_t j = 0; j < temp_stat[i].size(); ++j) {
                sparse_stat[i][j] += temp_stat[i][j];
              }
            }
          }
        }
      }

    } else {
      _nodeStat[0].count = data->rows;

      for (size_t i = 0; i < data->columns_sparse; ++i) {
        sparse_stat[i][0] = data->lil_column[i].size();
      }
      sum_type sum;
      init(sum);

#pragma omp parallel
      {
        sum_type sum_thread;
        init(sum_thread);
#pragma omp for simd
        for (size_t i = 0; i < data->rows; ++i) {
          sum_thread += grad_slice[i];
        }
#pragma omp critical
        { sum += sum_thread; }
      }
      _nodeStat[0].sum_grad = sum;
    }

    size_t len = 1 << level;

    for (size_t i = 0; i < len; ++i) {
      _nodeStat[i].gain =
          0.0; // todo: gain_func(_nodeStat[i].count, _nodeStat[i].sum_grad);
      _bestSplit[i].Clean();
    }
  }

  void UpdateTree(const int level, RegTree *tree) const {
    unsigned int offset = Node::HeapOffset(level);

    const size_t len = 1 << level;

    for (size_t i = 0; i < len; ++i) {
      const Split<sum_type> &best = _bestSplit[i];
      tree->nodes[i + offset].threshold = best.split_value;
      tree->nodes[i + offset].split_by_true = best.split_by_true;
      tree->nodes[i + offset].fid = best.fid < 0 ? 0 : best.fid;
    }
  }

  void UpdateNodeIndex(const unsigned int level, const io::DataMatrix *data,
                       RegTree *tree) {
    unsigned int const offset = Node::HeapOffset(level);
    unsigned int const offset_next = Node::HeapOffset(level + 1);

#pragma omp parallel for simd
    for (size_t i = 0; i < data->rows; ++i) {
      const unsigned int node = _rowIndex2Node[i];
      const auto &best = _bestSplit[node];
      const bool isLeft =
          (best.fid < (int)data->columns_dense &&
           data->data[best.fid][i] <= best.split_value) ||
          (best.split_by_true &&
           std::binary_search(data->lil_row[i].begin(), data->lil_row[i].end(),
                              best.fid));
      _rowIndex2Node[i] = tree->ChildNode(node + offset, isLeft) - offset_next;
    }
  }

  void UpdateLeafWeight(RegTree *tree) const {
    const unsigned int offset_1 = Node::HeapOffset(tree->depth - 2);
    const unsigned int offset = Node::HeapOffset(tree->depth - 1);
    for (unsigned int i = 0, len = (1 << (tree->depth - 2)); i < len; ++i) {
      const Split<sum_type> &best = _bestSplit[i];
      const NodeStat<sum_type> &stat = _nodeStat[i];
      tree->leaf_level[tree->ChildNode(i + offset_1, true) - offset] =
          best.LeafWeight(param) * param.eta;
      tree->leaf_level[tree->ChildNode(i + offset_1, false) - offset] =
          best.LeafWeight(stat, param) * param.eta;
    }
  }
};

Garden::Garden(const TreeParam &param, const Verbose &verbose,
               const InternalConfiguration &cfg)
    : param(param), verbose(verbose), cfg(cfg), _init(false) {}

void Garden::GrowTree(io::DataMatrix *data, float *grad) {

  if (!_init) {
    switch (param.objective) {
    case LinearRegression: {
      auto obj = new RegressionObjective(data, param.initial_y);

      if (param.depth + 1 <= sizeof(unsigned char) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned char, float, double>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned char, float, float>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned short) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned short, float, double>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned short, float, float>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned int) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned int, float, double>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder = new TaylorApproximationBuilder<unsigned int, float, float>(
              param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned long int) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned long int, float, double>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder = new TaylorApproximationBuilder<unsigned int, float, float>(
              param, data, cfg, obj, verbose.booster);
        }
      } else
        throw "unsupported depth";
      _objective = obj;
    }

    break;
    case LogisticRegression: {
      auto obj = new LogisticRegressionObjective(data, param.initial_y);

      if (param.depth + 1 <= sizeof(unsigned char) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned char, float2, mydouble2>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned char, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned short) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned short, float2, mydouble2>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned short, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned int) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned int, float2, mydouble2>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned int, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned long int) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder = new TaylorApproximationBuilder<unsigned long int, float2,
                                                    mydouble2>(
              param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned long int, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else
        throw "unsupported depth";
      _objective = obj;
    } break;
    case SoftMaxOneVsAll: {
      auto obj =
          new SoftMaxObjective(data, param.labels_count, param.initial_y);

      if (param.depth + 1 <= sizeof(unsigned char) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned char, float2, mydouble2>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned char, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned short) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned short, float2, mydouble2>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned short, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned int) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder =
              new TaylorApproximationBuilder<unsigned int, float2, mydouble2>(
                  param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned int, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      } else if (param.depth + 1 <= sizeof(unsigned long int) * CHAR_BIT) {
        if (cfg.double_precision) {
          _builder = new TaylorApproximationBuilder<unsigned long int, float2,
                                                    mydouble2>(
              param, data, cfg, obj, verbose.booster);
        } else {
          _builder =
              new TaylorApproximationBuilder<unsigned long int, float2, float2>(
                  param, data, cfg, obj, verbose.booster);
        }
      }

      else
        throw "unsupported depth";
      _objective = obj;
    } break;
    default:
      throw "Unknown objective function " + param.objective;
    }

    data->Init();

    auto mem_per_rec = _builder->MemoryRequirementsPerRecord();
    size_t total;
    size_t free;

    cudaMemGetInfo(&free, &total);

    if (verbose.gpu) {
      printf("Total bytes %ld avaliable %ld \n", total, free);
      printf("Memory usage estimation %ld per record %ld in total \n",
             mem_per_rec, mem_per_rec * data->rows);
    }

    data->TransferToGPU(free * 9 / 10, verbose.gpu);

    _init = true;
  }

  if (grad == NULL) {
    _objective->UpdateGrad();
  } else {
    //          todo: fix
    //          data->grad = std::vector<float>(grad, grad + data->rows);
  }

  for (unsigned short i = 0; i < param.labels_count; ++i) {
    RegTree *tree = new RegTree(param.depth, i);
    _builder->GrowTree(tree, data, i);
    _trees.push_back(tree);
    if (grad == NULL) {
      _builder->PredictByGrownTree(tree, data, data->y_internal);
    }
  }
}

void Garden::UpdateByLastTree(io::DataMatrix *data) {
  if (data->y_internal.size() == 0)
    data->y_internal.resize(data->rows * param.labels_count,
                            _objective->IntoInternal(param.initial_y));
  for (auto it = _trees.end() - param.labels_count; it != _trees.end(); ++it) {
    (*it)->Predict(data, data->y_internal);
  }
}

void Garden::GetY(arboretum::io::DataMatrix *data,
                  std::vector<float> &out) const {
  out.resize(data->y_internal.size());
  _objective->FromInternal(data->y_internal, out);
}

void Garden::Predict(const arboretum::io::DataMatrix *data,
                     std::vector<float> &out) const {
  out.resize(data->rows * param.labels_count);
  std::vector<float> tmp(data->rows * param.labels_count);

  std::fill(tmp.begin(), tmp.end(), _objective->IntoInternal(param.initial_y));
  for (size_t i = 0; i < _trees.size(); ++i) {
    _trees[i]->Predict(data, tmp);
  }

  _objective->FromInternal(tmp, out);
}
}
}
