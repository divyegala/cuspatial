# Copyright (c) 2023, NVIDIA CORPORATION.

from libcpp.memory cimport unique_ptr

from cudf._lib.cpp.column.column cimport column

from cuspatial._lib.cpp.column.geometry_column_view cimport (
    geometry_column_view,
)


cdef extern from "cuspatial/distance/point_polygon_distance.hpp" \
        namespace "cuspatial" nogil:
    cdef unique_ptr[column] pairwise_point_polygon_distance(
        const geometry_column_view & multipoints,
        const geometry_column_view & multipolygons
    ) except +
