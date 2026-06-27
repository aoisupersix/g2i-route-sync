from g2i_route_sync.models import RouteSummary
from g2i_route_sync.sync import _normalize_to_unix_seconds, sort_routes_oldest_first


def test_normalize_to_unix_seconds_handles_variants():
    assert _normalize_to_unix_seconds(1_700_000_000) == 1_700_000_000.0
    # Milliseconds are scaled down to seconds.
    assert _normalize_to_unix_seconds(1_700_000_000_000) == 1_700_000_000.0
    assert _normalize_to_unix_seconds("1700000000") == 1_700_000_000.0
    assert _normalize_to_unix_seconds("2023-11-14T22:13:20Z") is not None


def test_normalize_to_unix_seconds_rejects_invalid():
    assert _normalize_to_unix_seconds(None) is None
    assert _normalize_to_unix_seconds(True) is None
    assert _normalize_to_unix_seconds(0) is None
    assert _normalize_to_unix_seconds("not a date") is None


def _route(route_id: str, create_time):
    return RouteSummary(
        route_id=route_id, name=route_id, raw={"createTime": create_time}
    )


def test_sort_routes_oldest_first():
    routes = [
        _route("new", 2_000),
        _route("old", 1_000),
        _route("no_ts", None),
    ]
    ordered = [r.route_id for r in sort_routes_oldest_first(routes)]
    # Oldest first; routes without timestamp sink to the end.
    assert ordered == ["old", "new", "no_ts"]


def test_sort_is_stable_for_missing_timestamps():
    routes = [_route("a", None), _route("b", None)]
    ordered = [r.route_id for r in sort_routes_oldest_first(routes)]
    assert ordered == ["a", "b"]
