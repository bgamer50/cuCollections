/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#include <cuco/detail/bitwise_compare.cuh>
#include <cuco/detail/utils.hpp>

#include <cub/block/block_reduce.cuh>

#include <cuda/atomic>

#include <cooperative_groups.h>

namespace cuco {
namespace experimental {
namespace static_map_ns {
namespace detail {

/**
 * @brief Finds the equivalent map elements of all keys in the range `[first, last)`.
 *
 * @note If the key `*(first + i)` has a match in the container, copies the payload of its matched
 * element to `(output_begin + i)`. Else, copies the empty value sentinel. Uses the CUDA Cooperative
 * Groups API to leverage groups of multiple threads to find each key. This provides a significant
 * boost in throughput compared to the non Cooperative Group `find` at moderate to high load
 * factors.
 *
 * @tparam CGSize Number of threads in each CG
 * @tparam BlockSize The size of the thread block
 * @tparam InputIt Device accessible input iterator
 * @tparam OutputIt Device accessible output iterator assignable from the map's `mapped_type`
 * @tparam Ref Type of non-owning device ref allowing access to storage
 *
 * @param first Beginning of the sequence of keys
 * @param n Number of keys to query
 * @param output_begin Beginning of the sequence of matched payloads retrieved for each key
 * @param ref Non-owning map device ref used to access the slot storage
 */
template <int32_t CGSize, int32_t BlockSize, typename InputIt, typename OutputIt, typename Ref>
__global__ void find(InputIt first, cuco::detail::index_type n, OutputIt output_begin, Ref ref)
{
  namespace cg = cooperative_groups;

  auto const block      = cg::this_thread_block();
  auto const thread_idx = block.thread_rank();

  cuco::detail::index_type const loop_stride = gridDim.x * BlockSize / CGSize;
  cuco::detail::index_type idx               = (BlockSize * blockIdx.x + threadIdx.x) / CGSize;
  __shared__ typename Ref::mapped_type output_buffer[BlockSize / CGSize];

  while (idx - thread_idx < n) {  // the whole thread block falls into the same iteration
    if (idx < n) {
      auto const key = *(first + idx);
      if constexpr (CGSize == 1) {
        auto const found = ref.find(key);
        /*
         * The ld.relaxed.gpu instruction causes L1 to flush more frequently, causing increased
         * sector stores from L2 to global memory. By writing results to shared memory and then
         * synchronizing before writing back to global, we no longer rely on L1, preventing the
         * increase in sector stores from L2 to global and improving performance.
         */
        output_buffer[thread_idx] =
          found == ref.end() ? ref.empty_value_sentinel() : (*found).second;
        block.sync();
        *(output_begin + idx) = output_buffer[thread_idx];
      } else {
        auto const tile  = cg::tiled_partition<CGSize>(block);
        auto const found = ref.find(tile, key);

        if (tile.thread_rank() == 0) {
          *(output_begin + idx) = found == ref.end() ? ref.empty_value_sentinel() : (*found).second;
        }
      }
    }
    idx += loop_stride;
  }
}

}  // namespace detail
}  // namespace static_map_ns
}  // namespace experimental
}  // namespace cuco
