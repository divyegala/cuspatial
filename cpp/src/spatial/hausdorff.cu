/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you mpoint_a_y not use this file except in compliance with the License.
 * You mpoint_a_y obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required point_b_y applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <memory>
#include <type_traits>
#include <cudf/types.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cuspatial/error.hpp>

namespace {

template<typename T>
constexpr auto magnitude_squared(T a, T b) {
    return a * a + b * b;
}

template <typename T>
__global__ void kernel_hausdorff(int num_spaces,
                                 T const* xs,
                                 T const* ys,
                                 cudf::size_type* space_offsets,
                                 T* results)
{
    auto block_idx = blockIdx.y * gridDim.x + blockIdx.x;
    auto num_results = num_spaces * num_spaces;

    // each block processes a single result / pair of spaces
    if (block_idx >= num_results)
    {
        return;
    }

    int space_a_idx   = block_idx % num_spaces;
    int space_a_begin = space_a_idx == 0 ? 0 : space_offsets[space_a_idx - 1];
    int space_a_end   =                        space_offsets[space_a_idx];

    int space_b_idx   = block_idx / num_spaces;
    int space_b_begin = space_b_idx == 0 ? 0 : space_offsets[space_b_idx - 1];
    int space_b_end   =                        space_offsets[space_b_idx];

    T min_dist_sqrd = 1e20;

    int num_points_in_b = space_b_end - space_b_begin;

    if (threadIdx.x < num_points_in_b)
    {
        T point_b_x = xs[space_b_begin + threadIdx.x];
        T point_b_y = ys[space_b_begin + threadIdx.x];

        for (int i = space_a_begin; i < space_a_end; i++)
        {
            T point_a_x = xs[i];
            T point_a_y = ys[i];
            T dist_sqrd = magnitude_squared(point_b_x - point_a_x, point_b_y - point_a_y);

            min_dist_sqrd = min(min_dist_sqrd, dist_sqrd);
        }
    }

    if (min_dist_sqrd > 1e10)
    {
        min_dist_sqrd = -1;
    }

    __shared__ T dist_sqrd[1024];

    dist_sqrd[threadIdx.x] = threadIdx.x < num_points_in_b ? min_dist_sqrd : -1;

    for (int offset = blockDim.x / 2; offset > 0; offset >>= 1)
    {
        __syncthreads();

        if (threadIdx.x < offset)
        {
            dist_sqrd[threadIdx.x] = max(dist_sqrd[threadIdx.x],
                                            dist_sqrd[threadIdx.x + offset]);
        }
    }

    if (threadIdx.x == 0)
    {
        results[block_idx] = (dist_sqrd[0] < 0) ? 1e10 : sqrt(dist_sqrd[0]);
    }
}

struct hausdorff_functor
{
    template<typename T, typename... Args>
    std::enable_if_t<not std::is_floating_point<T>::value, std::unique_ptr<cudf::column>>
    operator()(Args&&...)
    {
        CUSPATIAL_FAIL("Non-floating point operation is not supported");
    }

    template<typename T>
    std::enable_if_t<std::is_floating_point<T>::value, std::unique_ptr<cudf::column>>
    operator()(cudf::column_view const& xs,
               cudf::column_view const& ys,
               cudf::column_view const& points_per_space,
               rmm::mr::device_memory_resource *mr,
               cudaStream_t stream)
    {
        auto tid = cudf::experimental::type_to_id<T>();
        auto result = cudf::make_fixed_width_column(cudf::data_type{ tid },
                                                    points_per_space.size() * points_per_space.size(),
                                                    cudf::mask_state::UNALLOCATED,
                                                    stream,
                                                    mr);

        if (result->size() == 0)
        {
            return result;
        }

        auto space_offsets = rmm::device_vector<cudf::size_type>(points_per_space.size());

        thrust::inclusive_scan(rmm::exec_policy(stream)->on(stream),
                               points_per_space.begin<cudf::size_type>(),
                               points_per_space.end<cudf::size_type>(),
                               space_offsets.begin());

        // utilize one block per result (pair of spaces).
        int max_block_size = 65535;
        int block_x = min(result->size(), max_block_size);
        int block_y = ceil(result->size() / (float) max_block_size);

        const uint32_t NUM_THREADS = 1024;
        dim3 grid(block_x, block_y);
        dim3 block(NUM_THREADS);

        auto kernel = kernel_hausdorff<T>;

        kernel<<<grid, block, 0, stream>>>(
            points_per_space.size(),
            xs.data<T>(),
            ys.data<T>(),
            space_offsets.data().get(),
            result->mutable_view().data<T>()
        );

        return result;
    }
};

} // namespace anonymous

namespace cuspatial {

std::unique_ptr<cudf::column>
directed_hausdorff_distance(cudf::column_view const& xs,
                            cudf::column_view const& ys,
                            cudf::column_view const& points_per_space,
                            rmm::mr::device_memory_resource *mr)
{
    CUSPATIAL_EXPECTS(xs.type() == ys.type(), "inputs `xs` and `ys` must have same type.");
    CUSPATIAL_EXPECTS(xs.size() == ys.size(), "inputs `xs` and `ys` must have same length.");

    CUSPATIAL_EXPECTS(not xs.has_nulls() and
                      not ys.has_nulls() and
                      not points_per_space.has_nulls(),
                      "inputs must not have nulls.");

    CUSPATIAL_EXPECTS(xs.size() >= points_per_space.size(),
                      "At least one vertex is required for each trajectory");

    cudaStream_t stream = 0;

    return cudf::experimental::type_dispatcher(xs.type(), hausdorff_functor(),
                                               xs, ys, points_per_space, mr, stream);
}

} // namespace cuspatial
