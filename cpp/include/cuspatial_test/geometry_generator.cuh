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

#include <cuspatial_test/random.cuh>
#include <cuspatial_test/vector_factories.cuh>

#include <cuspatial/cuda_utils.hpp>
#include <cuspatial/error.hpp>
#include <cuspatial/experimental/ranges/multipolygon_range.cuh>
#include <cuspatial/vec_2d.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/sequence.h>
#include <thrust/tabulate.h>

namespace cuspatial {
namespace test {

/**
 * @brief Struct to store the parameters of the multipolygon array generator
 *
 * @tparam T Type of the coordinates
 */
template <typename T>
struct multipolygon_generator_parameter {
  using element_t = T;

  std::size_t num_multipolygons;
  std::size_t num_polygons_per_multipolygon;
  std::size_t num_holes_per_polygon;
  std::size_t num_edges_per_ring;
  vec_2d<T> centroid;
  T radius;

  CUSPATIAL_HOST_DEVICE std::size_t num_polygons()
  {
    return num_multipolygons * num_polygons_per_multipolygon;
  }
  CUSPATIAL_HOST_DEVICE std::size_t num_rings() { return num_polygons() * num_rings_per_polygon(); }
  CUSPATIAL_HOST_DEVICE std::size_t num_coords() { return num_rings() * num_vertices_per_ring(); }
  CUSPATIAL_HOST_DEVICE std::size_t num_vertices_per_ring() { return num_edges_per_ring + 1; }
  CUSPATIAL_HOST_DEVICE std::size_t num_rings_per_polygon() { return num_holes_per_polygon + 1; }
  CUSPATIAL_HOST_DEVICE T hole_radius() { return radius / (num_holes_per_polygon + 1); }
};

/**
 * @brief Generate coordinates for the ring based on the local index of the point.
 *
 * The ring is generated by walking a point around a centroid with a fixed radius.
 * Each step has equal angles.
 *
 * @tparam T Type of coordinate
 * @param point_local_idx Local index of the point
 * @param num_edges Number of sides of the polygon
 * @param centroid Centroid of the ring
 * @param radius Radius of the ring
 * @return Coordinate of the point
 */
template <typename T>
vec_2d<T> __device__ generate_ring_coordinate(std::size_t point_local_idx,
                                              std::size_t num_edges,
                                              vec_2d<T> centroid,
                                              T radius)
{
  // Overrides last coordinate to make sure ring is closed.
  if (point_local_idx == num_edges) return vec_2d<T>{centroid.x + radius, centroid.y};

  T angle = (2.0 * M_PI * point_local_idx) / num_edges;

  return vec_2d<T>{centroid.x + radius * cos(angle), centroid.y + radius * sin(angle)};
}

/**
 * @brief Apply displacement to the centroid of a polygon.
 *
 * The `i`th polygon's centroid is displaced by (3*radius*i, 0). This makes sure
 * polygons within a multipolygon does not overlap.
 *
 * @tparam T Type of the coordinates
 * @param centroid The first centroid of the polygons
 * @param part_local_idx Local index of the polygon
 * @param radius Radius of each polygon
 * @return Displaced centroid
 */
template <typename T>
vec_2d<T> __device__ polygon_centroid_displacement(vec_2d<T> centroid,
                                                   std::size_t part_local_idx,
                                                   T radius)
{
  return centroid + vec_2d<T>{part_local_idx * radius * T{3.0}, T{0.0}};
}

/**
 * @brief Given a ring centroid, displace it based on its ring index.
 *
 * A Polygon contains at least 1 shell. It may contain 0 or more holes.
 * The shell is the leading ring of the polygon (index 0). All holes' centroid
 * has the same y value as the shell's centroid. Holes are aligned from left
 * to right on the center axis, with no overlapping areas. It may look like:
 *
 *            ******
 *        **          **
 *      *                *
 *    *                    *
 *   *                      *
 *  @@@ @@@ @@@ @@@          *
 * @   @   @   @   @          *
 * @   @   @   @   @          *
 * @   @   @   @   @          *
 * *@@@ @@@ @@@ @@@           *
 *  *                        *
 *   *                      *
 *    *                    *
 *      *                *
 *        **          **
 *            ******
 *
 *
 * @tparam T Type of the coordinates
 * @param centroid The center of the polygon
 * @param ring_local_idx Local index of the ring
 * @param radius Radius of the polygon
 * @param hole_radius Radius of each hole
 * @return Centroid of the ring
 */
template <typename T>
vec_2d<T> __device__
ring_centroid_displacement(vec_2d<T> centroid, std::size_t ring_local_idx, T radius, T hole_radius)
{
  // This is a shell
  if (ring_local_idx == 0) { return centroid; }

  // This is a hole
  ring_local_idx -= 1;  // offset hole indices to be 0-based
  T max_hole_displacement = radius - hole_radius;
  T displacement_x        = -max_hole_displacement + ring_local_idx * hole_radius * 2;
  T displacement_y        = 0.0;
  return centroid + vec_2d<T>{displacement_x, displacement_y};
}

/**
 * @brief Kernel to generate coordinates for multipolygon arrays.
 *
 * @pre This kernel requires that the three offset arrays (geometry, part, ring) has been prefilled
 * with the correct offsets.
 *
 * @tparam T Type of the coordinate
 * @tparam MultipolygonRange A specialization of `multipolygon_range`
 * @param multipolygons The range of multipolygons
 * @param params Parameters to generate the mulitpolygons
 */
template <typename T, typename MultipolygonRange>
void __global__ generate_multipolygon_array_coordinates(MultipolygonRange multipolygons,
                                                        multipolygon_generator_parameter<T> params)
{
  for (auto idx = threadIdx.x + blockIdx.x * blockDim.x; idx < multipolygons.num_points();
       idx += gridDim.x * blockDim.x) {
    auto ring_idx     = multipolygons.ring_idx_from_point_idx(idx);
    auto part_idx     = multipolygons.part_idx_from_ring_idx(ring_idx);
    auto geometry_idx = multipolygons.geometry_idx_from_part_idx(part_idx);

    auto point_local_idx = idx - params.num_vertices_per_ring() * ring_idx;
    auto ring_local_idx  = ring_idx - params.num_rings_per_polygon() * part_idx;
    auto part_local_idx  = part_idx - params.num_polygons_per_multipolygon * geometry_idx;

    auto centroid = ring_centroid_displacement(
      polygon_centroid_displacement(params.centroid, part_local_idx, params.radius),
      ring_local_idx,
      params.radius,
      params.hole_radius());

    if (ring_local_idx == 0)  // Generate coordinate for shell
      multipolygons.point_begin()[idx] = generate_ring_coordinate(
        point_local_idx, params.num_edges_per_ring, centroid, params.radius);
    else  // Generate coordinate for holes
      multipolygons.point_begin()[idx] = generate_ring_coordinate(
        point_local_idx, params.num_edges_per_ring, centroid, params.hole_radius());
  }
}

/**
 * @brief Helper to generate multipolygon arrays used for tests and benchmarks.
 *
 * @tparam T The floating point type for the coordinates
 * @param params The parameters to set for the multipolygon array
 * @param stream The CUDA stream to use for device memory operations and kernel launches
 * @return A cuspatial::test::multipolygon_array object.
 */
template <typename T>
auto generate_multipolygon_array(multipolygon_generator_parameter<T> params,
                                 rmm::cuda_stream_view stream)
{
  rmm::device_uvector<std::size_t> geometry_offsets(params.num_multipolygons + 1, stream);
  rmm::device_uvector<std::size_t> part_offsets(params.num_polygons() + 1, stream);
  rmm::device_uvector<std::size_t> ring_offsets(params.num_rings() + 1, stream);
  rmm::device_uvector<vec_2d<T>> coordinates(params.num_coords(), stream);

  thrust::sequence(rmm::exec_policy(stream),
                   ring_offsets.begin(),
                   ring_offsets.end(),
                   std::size_t{0},
                   params.num_vertices_per_ring());

  thrust::sequence(rmm::exec_policy(stream),
                   part_offsets.begin(),
                   part_offsets.end(),
                   std::size_t{0},
                   params.num_rings_per_polygon());

  thrust::sequence(rmm::exec_policy(stream),
                   geometry_offsets.begin(),
                   geometry_offsets.end(),
                   std::size_t{0},
                   params.num_polygons_per_multipolygon);

  auto multipolygons = multipolygon_range(geometry_offsets.begin(),
                                          geometry_offsets.end(),
                                          part_offsets.begin(),
                                          part_offsets.end(),
                                          ring_offsets.begin(),
                                          ring_offsets.end(),
                                          coordinates.begin(),
                                          coordinates.end());

  auto [tpb, nblocks] = grid_1d(multipolygons.num_points());

  generate_multipolygon_array_coordinates<T><<<nblocks, tpb, 0, stream>>>(multipolygons, params);

  CUSPATIAL_CHECK_CUDA(stream.value());

  return make_multipolygon_array<std::size_t, vec_2d<T>>(std::move(geometry_offsets),
                                                         std::move(part_offsets),
                                                         std::move(ring_offsets),
                                                         std::move(coordinates));
}

/**
 * @brief Struct to store the parameters of the multipoint aray
 *
 * @tparam T Type of the coordinates
 */
template <typename T>
struct multipoint_generator_parameter {
  using element_t = T;

  std::size_t num_multipoints;
  std::size_t num_points_per_multipoints;
  vec_2d<T> lower_left;
  vec_2d<T> upper_right;

  CUSPATIAL_HOST_DEVICE std::size_t num_points()
  {
    return num_multipoints * num_points_per_multipoints;
  }
};

/**
 * @brief Helper to generate random multipoints within a range
 *
 * @tparam T The floating point type for the coordinates
 * @param params Parameters to specify for the multipoints
 * @param stream The CUDA stream to use for device memory operations and kernel launches
 * @return a cuspatial::test::multipoint_array object
 */
template <typename T>
auto generate_multipoint_array(multipoint_generator_parameter<T> params,
                               rmm::cuda_stream_view stream)
{
  rmm::device_uvector<vec_2d<T>> coordinates(params.num_points(), stream);
  rmm::device_uvector<std::size_t> offsets(params.num_multipoints + 1, stream);

  thrust::sequence(rmm::exec_policy(stream),
                   offsets.begin(),
                   offsets.end(),
                   std::size_t{0},
                   params.num_points_per_multipoints);

  auto engine_x = deterministic_engine(params.num_points());
  auto engine_y = deterministic_engine(2 * params.num_points());

  auto x_dist = make_uniform_dist(params.lower_left.x, params.upper_right.x);
  auto y_dist = make_uniform_dist(params.lower_left.y, params.upper_right.y);

  auto point_gen =
    point_generator(params.lower_left, params.upper_right, engine_x, engine_y, x_dist, y_dist);

  thrust::tabulate(rmm::exec_policy(stream), coordinates.begin(), coordinates.end(), point_gen);

  return make_multipoint_array(std::move(offsets), std::move(coordinates));
}

}  // namespace test
}  // namespace cuspatial
