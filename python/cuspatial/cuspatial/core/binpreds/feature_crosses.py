# Copyright (c) 2023, NVIDIA CORPORATION.

from cuspatial.core.binpreds.binpred_interface import ImpossiblePredicate
from cuspatial.core.binpreds.feature_equals import EqualsPredicateBase
from cuspatial.core.binpreds.feature_intersects import IntersectsPredicateBase
from cuspatial.utils.binpred_utils import (
    LineString,
    MultiPoint,
    Point,
    Polygon,
    _false_series,
)


class CrossesPredicateBase(EqualsPredicateBase):
    """Base class for binary predicates that are defined in terms of a
    the equals binary predicate. For example, a Point-Point Crosses
    predicate is defined in terms of a Point-Point Equals predicate.

    Used by:
    (Point, Polygon)
    (Polygon, Point)
    (Polygon, MultiPoint)
    (Polygon, LineString)
    (Polygon, Polygon)
    """

    pass


class CrossesByIntersectionPredicate(IntersectsPredicateBase):
    def _compute_predicate(self, lhs, rhs, preprocessor_result):
        intersects = rhs._basic_intersects(lhs)
        equals = rhs._basic_equals(lhs)
        return intersects & ~equals


class PolygonLineStringCrosses(CrossesByIntersectionPredicate):
    def _compute_predicate(self, lhs, rhs, preprocessor_result):
        intersects_through = lhs._basic_intersects_through(rhs)
        # intersects_any = lhs._basic_intersects(rhs)
        # intersects_points = lhs._basic_intersects_points(rhs)
        equals = rhs._basic_equals(lhs)
        # contains_any = lhs._basic_contains_any(rhs)
        contains_all = lhs._basic_contains_all(rhs)
        return ~contains_all & ~equals & intersects_through


class LineStringPolygonCrosses(PolygonLineStringCrosses):
    def _preprocess(self, lhs, rhs):
        """Note the order of arguments is reversed."""
        return super()._preprocess(rhs, lhs)


class PointPointCrosses(CrossesPredicateBase):
    def _preprocess(self, lhs, rhs):
        """Points can't cross other points, so we return False."""
        return _false_series(len(lhs))


class PolygonPolygonCrosses(PolygonLineStringCrosses):
    pass


DispatchDict = {
    (Point, Point): PointPointCrosses,
    (Point, MultiPoint): ImpossiblePredicate,
    (Point, LineString): ImpossiblePredicate,
    (Point, Polygon): CrossesPredicateBase,
    (MultiPoint, Point): ImpossiblePredicate,
    (MultiPoint, MultiPoint): ImpossiblePredicate,
    (MultiPoint, LineString): ImpossiblePredicate,
    (MultiPoint, Polygon): ImpossiblePredicate,
    (LineString, Point): ImpossiblePredicate,
    (LineString, MultiPoint): ImpossiblePredicate,
    (LineString, LineString): CrossesByIntersectionPredicate,
    (LineString, Polygon): LineStringPolygonCrosses,
    (Polygon, Point): CrossesPredicateBase,
    (Polygon, MultiPoint): CrossesPredicateBase,
    (Polygon, LineString): PolygonLineStringCrosses,
    (Polygon, Polygon): PolygonPolygonCrosses,
}
