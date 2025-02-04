/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cuspatial_test/base_fixture.hpp>

#include <cuspatial/error.hpp>
#include <cuspatial/trajectory.hpp>

struct TrajectoryBoundingBoxesErrorTest : public cuspatial::test::BaseFixture {};

TEST_F(TrajectoryBoundingBoxesErrorTest, SizeMismatch)
{
  auto const size = 1000;

  {
    auto id = cudf::column(rmm::device_uvector<cudf::size_type>(size, rmm::cuda_stream_default));
    auto xs = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));
    auto ys = cudf::column(rmm::device_uvector<float>(size / 2, rmm::cuda_stream_default));

    EXPECT_THROW(cuspatial::trajectory_bounding_boxes(1, id, xs, ys, this->mr()),
                 cuspatial::logic_error);
  }
  {
    auto id = cudf::column(rmm::device_uvector<int>(size / 2, rmm::cuda_stream_default));
    auto xs = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));
    auto ys = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));
    EXPECT_THROW(cuspatial::trajectory_bounding_boxes(1, id, xs, ys, this->mr()),
                 cuspatial::logic_error);
  }
}

TEST_F(TrajectoryBoundingBoxesErrorTest, TypeError)
{
  auto const size = 1000;

  {
    auto id =
      cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));  // not integer
    auto xs = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));
    auto ys = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));
    EXPECT_THROW(cuspatial::trajectory_bounding_boxes(1, id, xs, ys, this->mr()),
                 cuspatial::logic_error);
  }

  {
    // x-y type mismatch
    auto id = cudf::column(rmm::device_uvector<cudf::size_type>(size, rmm::cuda_stream_default));
    auto xs = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));
    auto ys = cudf::column(rmm::device_uvector<double>(size, rmm::cuda_stream_default));
    EXPECT_THROW(cuspatial::trajectory_bounding_boxes(1, id, xs, ys, this->mr()),
                 cuspatial::logic_error);
  }
}

TEST_F(TrajectoryBoundingBoxesErrorTest, Nulls)
{
  auto const size = 1000;

  {
    auto id = cudf::column(rmm::device_uvector<cudf::size_type>(size, rmm::cuda_stream_default));
    auto xs = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));
    auto ys = cudf::column(rmm::device_uvector<float>(size, rmm::cuda_stream_default));

    auto nulls = rmm::device_uvector<int>(1000, rmm::cuda_stream_default);
    cudaMemsetAsync(nulls.data(), 0xcccc, nulls.size(), rmm::cuda_stream_default.value());
    auto nulls_buffer = nulls.release();
    id.set_null_mask(nulls_buffer);
    EXPECT_THROW(cuspatial::trajectory_bounding_boxes(1, id, xs, ys, this->mr()),
                 cuspatial::logic_error);
  }
}
